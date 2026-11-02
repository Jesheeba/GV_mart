// Narrow, OTP-only fast dispatch path (phase 2, Item 2 of docs/backlog-product-gaps.md's
// "OTP-verified customer Google account linking" feature). Triggered directly from inside
// request_customer_link_code() via pg_net (public.wa_otp_fast_dispatch_invoke,
// 20261120100000_customer_link_otp.sql) immediately after it enqueues a customer_link_otp
// whatsapp_outbox row, because the GitHub Actions cron that would otherwise pick it up
// (wa-milestone-dispatch, every 5 minutes nominally) fires every 3-7 HOURS in practice —
// hopeless against that challenge's own 10-minute expiry. See gv-mart/DECISIONS.md section 9 for
// the full design writeup and the independent security review of this specific addition.
//
// Deliberately NOT a copy of wa-dispatch-now/index.ts: that function resolves the CALLER's own
// org via their JWT + a profiles row lookup, which does not exist yet for a customer linking a
// Google account for the first time — the exact gap this function exists to close (see
// gv-mart/docs/DECISIONS.md section 2). This one instead takes org_id directly in the request
// body and authenticates the caller with a DEDICATED vault/Edge-Function secret pair
// (WA_OTP_FAST_DISPATCH_SECRET), deliberately separate from CRON_SECRET, so a compromise of one
// secret never grants the other.
//
// HARD SCOPE, enforced here in code, not just by convention or by caller discipline: this always
// calls runMilestoneDispatch with refTypes locked to ['customer_link_otp'] — the literal array
// below, never derived from the request body (which has no field that could widen it). It must
// never become a general low-latency path for service_ticket/service_visit/invoice/
// purchase_quote_request, which stay on the existing cron + wa-dispatch-now cadence precisely so
// this project's existing batching/pacing design for those message types stays intact.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { runMilestoneDispatch } from "../_shared/wa-milestone-dispatch-core.ts"

const OTP_ONLY_REF_TYPES = ["customer_link_otp"] as const

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const secret = Deno.env.get("WA_OTP_FAST_DISPATCH_SECRET")
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!secret || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing WA_OTP_FAST_DISPATCH_SECRET or Supabase service credentials)" }, 500)
  }

  // Constant-shape check (no early return based on string content beyond this single comparison)
  // — this endpoint has nothing else to leak: it returns a dispatch summary, never anything about
  // a specific phone number or customer, so there is no secondary response-shape oracle here even
  // though this is itself new attack surface introduced by this phase's work (see the independent
  // review requested in DECISIONS.md section 9).
  const authHeader = req.headers.get("Authorization")
  if (authHeader !== `Bearer ${secret}`) return jsonResponse({ error: "Unauthorized" }, 401)

  let body: { org_id?: string }
  try {
    body = await req.json()
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400)
  }
  const orgId = typeof body.org_id === "string" && body.org_id.length > 0 ? body.org_id : null
  if (!orgId) return jsonResponse({ error: "org_id is required" }, 400)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const result = await runMilestoneDispatch(admin, orgId, { refTypes: OTP_ONLY_REF_TYPES })
  return jsonResponse({ orgId, ...result }, result.queryError ? 500 : 200)
})
