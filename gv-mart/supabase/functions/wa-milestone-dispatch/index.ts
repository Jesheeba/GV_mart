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
//
// The actual scan-and-send logic now lives in
// ../_shared/wa-milestone-dispatch-core.ts, shared verbatim with
// wa-dispatch-now (an on-demand, single-org, user-JWT-authenticated sibling
// that fires right after a milestone write instead of waiting for this
// cron tick) — this file keeps only the cron entrypoint: the CRON_SECRET
// check, the all-orgs loop, and the pacing gate below.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { runMilestoneDispatch } from "../_shared/wa-milestone-dispatch-core.ts"
import { markJobRan, shouldRunJob } from "../_shared/wa-job-pacing.ts"
import { checkAndAlertStaleJobs, recordHeartbeat } from "../_shared/cron-heartbeat.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
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

  // Unconditional, every invocation, before the pacing gate below — this is
  // the fastest-cadence job (every 5 minutes), so it's the primary heartbeat
  // monitor for its two daily-cadence siblings. See _shared/cron-heartbeat.ts.
  await checkAndAlertStaleJobs(admin)

  const { data: orgs, error: orgsError } = await admin.from("organizations").select("id")
  if (orgsError) {
    await recordHeartbeat(admin, "wa_milestone_dispatch", "error", orgsError.message)
    return jsonResponse({ error: orgsError.message }, 500)
  }

  const errors: string[] = []
  const results = []
  for (const org of orgs ?? []) {
    if (!(await shouldRunJob(admin, org.id, "milestone_dispatch"))) {
      results.push({ orgId: org.id, skipped: true })
      continue
    }
    const result = await runMilestoneDispatch(admin, org.id)
    if (result.queryError) errors.push(`[${org.id}] ${result.queryError}`)
    await markJobRan(admin, org.id, "milestone_dispatch")
    results.push({ orgId: org.id, ...result })
  }

  await recordHeartbeat(admin, "wa_milestone_dispatch", errors.length > 0 ? "error" : "ok", errors.join("; "))

  // Non-2xx on real errors — same reasoning as wa-scheduled-tasks/index.ts:
  // this workflow's own step explicitly checks the HTTP status is < 300, so
  // 500 here turns the GitHub Actions run red instead of a silently
  // swallowed per-org error hiding behind an unconditional 200.
  return jsonResponse({ ranAt: new Date().toISOString(), results, errors }, errors.length > 0 ? 500 : 200)
})
