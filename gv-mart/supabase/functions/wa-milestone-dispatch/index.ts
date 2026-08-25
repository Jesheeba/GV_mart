// Poller for the milestone-trigger bypass: _milestone_ticket_notify,
// _milestone_visit_notify, _milestone_invoice_notify (see
// 20260819170000_whatsapp_templates_and_kill_switch.sql), and now also
// _auto_draft_purchase_order's supplier quote-request fan-out (see
// 20260825150000_supplier_rfq_wa_automation.sql — that migration's own
// "Blocker 0" note) write directly into whatsapp_outbox via raw SQL INSERT,
// never calling sendMessage() — so now that sendMessage() does real Wasi
// dispatch, those rows would silently never leave the server. This
// function finds them and pushes each one through the real sendMessage() call.
//
// Kept as its own dedicated function rather than a 4th job bolted onto
// wa-scheduled-tasks: that function's three existing jobs (AMC reminders,
// feedback requests, failed-send retries) are correctly daily-cadence —
// this one needs to run every few minutes so a "your ticket is booked"
// message doesn't sit unsent for up to a day. Two different cadences on
// one function would mean the daily jobs re-running every 5 minutes too
// (harmless given their own dedupe logic, but wasteful) or splitting the
// schedule awkwardly — a separate function with its own schedule is
// cleaner. See .github/workflows/wa-milestone-dispatch.yml.
//
// Deliberately does NOT broaden to "any undispatched row" — that would
// also catch the bot's own interactive/menu replies, which are still on
// the log-only stub on purpose (Wasi's interactive-message format isn't
// confirmed yet). Scoped precisely to the ref_type values only these
// trigger-side writers ever produce.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "../_shared/whatsapp.ts"
import { markJobRan, shouldRunJob } from "../_shared/wa-job-pacing.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

const MILESTONE_REF_TYPES = ["service_ticket", "service_visit", "invoice", "purchase_quote_request"] as const

type StuckOutboxRow = {
  id: string
  to_mobile: string | null
  customer_id: string | null
  template: string
  type: string | null
  payload: { body?: string } | null
  ref_type: string | null
  ref_id: string | null
}

async function runMilestoneDispatch(admin: SupabaseClient, orgId: string): Promise<{ dispatched: number; skippedNoBody: number }> {
  const { data: rows, error } = await admin
    .from("whatsapp_outbox")
    .select("id, to_mobile, customer_id, template, type, payload, ref_type, ref_id")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .is("wa_message_id", null)
    .is("retried_at", null)
    .in("ref_type", MILESTONE_REF_TYPES)

  if (error) {
    console.error("wa-milestone-dispatch: whatsapp_outbox query failed", error)
    return { dispatched: 0, skippedNoBody: 0 }
  }

  let dispatched = 0
  let skippedNoBody = 0

  for (const row of (rows ?? []) as StuckOutboxRow[]) {
    const body = row.payload?.body
    // No whatsapp_templates row exists for this milestone name yet (see
    // _wa_render_template's found:false path) — there's nothing readable
    // to send. Mark retried_at anyway so this doesn't get re-checked
    // every 5 minutes forever; the real fix is adding the missing
    // template row (Automation > Templates), not fabricating content here.
    if (!body) {
      console.error("wa-milestone-dispatch: skipping row with no renderable body — missing template for", row.template, row.id)
      skippedNoBody++
      await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
      continue
    }
    if (!row.to_mobile) {
      console.error("wa-milestone-dispatch: skipping row with no to_mobile", row.id)
      await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
      continue
    }

    await sendMessage(admin, {
      orgId,
      to: row.to_mobile,
      customerId: row.customer_id,
      template: row.template,
      body,
      type: (row.type as "text" | "template" | "interactive" | "media" | undefined) ?? "text",
      refType: row.ref_type,
      refId: row.ref_id,
    })
    dispatched++

    // Same bookkeeping shape as runFailedSendRetries: the real outcome
    // (sent/failed, wa_message_id, error) lives on the NEW row sendMessage()
    // just inserted, not this one — this row is only marked so the next
    // poll doesn't pick it up again.
    await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
  }

  return { dispatched, skippedNoBody }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const cronSecret = Deno.env.get("CRON_SECRET")
  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!cronSecret || !supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing CRON_SECRET or Supabase service credentials)" }, 500)
  }

  const authHeader = req.headers.get("Authorization")
  if (authHeader !== `Bearer ${cronSecret}`) return jsonResponse({ error: "Unauthorized" }, 401)

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const { data: orgs, error: orgsError } = await admin.from("organizations").select("id")
  if (orgsError) return jsonResponse({ error: orgsError.message }, 500)

  const results = []
  for (const org of orgs ?? []) {
    if (!(await shouldRunJob(admin, org.id, "milestone_dispatch"))) {
      results.push({ orgId: org.id, skipped: true })
      continue
    }
    const result = await runMilestoneDispatch(admin, org.id)
    await markJobRan(admin, org.id, "milestone_dispatch")
    results.push({ orgId: org.id, ...result })
  }

  return jsonResponse({ ranAt: new Date().toISOString(), results })
})
