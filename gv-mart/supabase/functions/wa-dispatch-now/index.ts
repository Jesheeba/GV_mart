// On-demand sibling of wa-milestone-dispatch — see
// ../_shared/wa-milestone-dispatch-core.ts for the shared scan-and-send
// logic. That poller only runs every 5 minutes (GitHub Actions cron); this
// function lets the app nudge the exact same logic immediately, right after
// a staff/technician/customer action writes a service_ticket, service_visit,
// or invoice row that a milestone trigger turns into a pending
// whatsapp_outbox row. The cron poller is left completely untouched and
// keeps running on its own schedule regardless — it's the automatic safety
// net for whatever this on-demand call misses (Wasi down, a network blip,
// the client never calling this at all). Fire-and-forget by design: callers
// should never await this for their own success/failure, per the
// hybrid-delivery plan (a WhatsApp send failing here must never block or
// fail the ticket/sale/invoice action that triggered it).
//
// Auth: verify_jwt stays on (the project default — this file has no
// [functions.wa-dispatch-now] entry in config.toml, same as geocode and
// admin-create-technician), and the caller identity is resolved the exact
// same way admin-create-technician does it — admin.auth.getUser(token) then
// a profiles lookup for org_id — rather than a service-role bearer secret
// like wa-milestone-dispatch/wa-scheduled-tasks use for GitHub Actions.
//
// Deliberately no role check beyond "resolves to a real profile in an
// org": staff (admin panel), technicians (on-site invoice/AMC-sell/visit
// pages), and customers (AMC renewal) all need to call this, and
// current_org_id()'s own definition (`select org_id from profiles where id
// = auth.uid()`) makes no role distinction either — org_id is available to
// every role. There's no privilege escalation risk in allowing it broadly:
// this only flushes rows a SECURITY DEFINER trigger already wrote for that
// same org: it can't dispatch anything the caller couldn't already cause
// the cron poller to dispatch within 5 minutes anyway.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"
import { runMilestoneDispatch } from "../_shared/wa-milestone-dispatch-core.ts"
import { isJobEnabled } from "../_shared/wa-job-pacing.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight

  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Server is not configured (missing Supabase service credentials)" }, 500)
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const authHeader = req.headers.get("Authorization")
  const token = authHeader?.replace(/^Bearer /i, "")
  if (!token) return jsonResponse({ error: "Missing Authorization header" }, 401)

  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return jsonResponse({ error: "Invalid or expired session" }, 401)

  const { data: callerProfile, error: callerProfileErr } = await admin
    .from("profiles")
    .select("org_id")
    .eq("id", userRes.user.id)
    .single()
  if (callerProfileErr || !callerProfile) return jsonResponse({ error: "Caller profile not found" }, 403)

  const orgId = callerProfile.org_id as string

  if (!(await isJobEnabled(admin, orgId, "milestone_dispatch"))) {
    return jsonResponse({ orgId, skipped: true, reason: "milestone_dispatch disabled for this org" })
  }

  const result = await runMilestoneDispatch(admin, orgId)
  return jsonResponse({ orgId, ...result })
})
