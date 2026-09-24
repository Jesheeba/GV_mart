// WhatsApp Integration, Phase 3 — the periodic housekeeping pass this stack
// has no pg_cron for. Three jobs in one invocation, meant to run once daily:
//   1. AMC expiry reminders at 30/15/7 days out
//   2. Feedback request on a recently completed service ticket
//   3. Retry pass over whatsapp_outbox rows with status='failed'
//
// Scheduling mechanism: a GitHub Actions scheduled workflow (see
// .github/workflows/wa-scheduled-tasks.yml) calls this function daily over
// HTTP with a bearer secret. Chosen over enabling pg_cron/pg_net because
// this stack has deliberately avoided pg_cron elsewhere (see
// resolve_purchase_quote_requests's resolve-on-view pattern) — adding a new
// Postgres extension that reaches out over the network is a bigger,
// longer-lived infrastructure commitment than a workflow file already
// living in this repo's own CI, with no new extension enabled and nothing
// to manage inside the database.
//
// verify_jwt is off for this function too (see supabase/config.toml) —
// GitHub Actions can't send a Supabase session either. Authenticity is a
// plain bearer-secret check against CRON_SECRET, same shape as the
// webhook's own signature check one layer up (a different mechanism
// because the caller is different, not because this is less careful about it).
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "../_shared/whatsapp.ts"
import { markJobRan, shouldRunJob } from "../_shared/wa-job-pacing.ts"
import { MAX_SEND_ATTEMPTS, notifyGaveUpOnSend } from "../_shared/wa-milestone-dispatch-core.ts"
import { checkAndAlertStaleJobs, recordHeartbeat } from "../_shared/cron-heartbeat.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

const AMC_REMINDER_WINDOWS = [30, 15, 7] as const
// A daily job only needs to look back further than "since yesterday" if a
// run was ever missed — 25h (not 24h) gives a small buffer against the
// workflow firing a little early/late without risking a double-send.
const DEDUPE_LOOKBACK_HOURS = 25

async function alreadySentRecently(admin: SupabaseClient, orgId: string, refType: string, refId: string, template: string): Promise<boolean> {
  const { count } = await admin
    .from("whatsapp_outbox")
    .select("id", { count: "exact", head: true })
    .eq("org_id", orgId)
    .eq("ref_type", refType)
    .eq("ref_id", refId)
    .eq("template", template)
    .gte("created_at", new Date(Date.now() - DEDUPE_LOOKBACK_HOURS * 3_600_000).toISOString())
  return (count ?? 0) > 0
}

async function runAmcReminders(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ sent: number; skipped: number }> {
  let sent = 0
  let skipped = 0
  for (const days of AMC_REMINDER_WINDOWS) {
    const targetDate = new Date(Date.now() + days * 86_400_000).toISOString().slice(0, 10)
    const template = `amc_reminder_${days}`
    const { data: contracts, error } = await admin
      .from("amc_contracts")
      .select("id, customer_id, expiry_date, customers(name, mobile), products(name)")
      .eq("org_id", orgId)
      .eq("expiry_date", targetDate)
      .neq("status", "expired")
    if (error) {
      console.error("wa-scheduled-tasks: amc_contracts query failed", error)
      errors.push(`[${orgId}] amc_contracts query failed: ${error.message}`)
      continue
    }
    for (const contract of contracts ?? []) {
      const customer = contract.customers as unknown as { name: string; mobile: string } | null
      const product = contract.products as unknown as { name: string } | null
      if (!customer) continue
      if (await alreadySentRecently(admin, orgId, "amc_contracts", contract.id, template)) {
        skipped++
        continue
      }
      const body = `Hi ${customer.name}, your AMC for ${product?.name ?? "your product"} expires on ${contract.expiry_date} (in ${days} days). Reply to renew or talk to our team.`
      await sendMessage(admin, {
        orgId,
        to: customer.mobile,
        customerId: contract.customer_id,
        template,
        body,
        refType: "amc_contracts",
        refId: contract.id,
      })
      sent++
    }
  }
  return { sent, skipped }
}

async function runFeedbackRequests(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ sent: number; skipped: number }> {
  let sent = 0
  let skipped = 0
  const since = new Date(Date.now() - DEDUPE_LOOKBACK_HOURS * 3_600_000).toISOString()
  const { data: tickets, error } = await admin
    .from("service_tickets")
    .select("id, customer_id, name_of_complaint, updated_at, customers(name, mobile)")
    .eq("org_id", orgId)
    .eq("status", "completed")
    .gte("updated_at", since)
  if (error) {
    console.error("wa-scheduled-tasks: service_tickets query failed", error)
    errors.push(`[${orgId}] service_tickets query failed: ${error.message}`)
    return { sent, skipped }
  }
  for (const ticket of tickets ?? []) {
    const customer = ticket.customers as unknown as { name: string; mobile: string } | null
    if (!customer) continue
    if (await alreadySentRecently(admin, orgId, "service_tickets", ticket.id, "feedback_request")) {
      skipped++
      continue
    }
    const body = `Hi ${customer.name}, thanks for choosing GV Mart! How was your recent service (${ticket.name_of_complaint})? We'd love your feedback.`
    await sendMessage(admin, {
      orgId,
      to: customer.mobile,
      customerId: ticket.customer_id,
      template: "feedback_request",
      body,
      refType: "service_tickets",
      refId: ticket.id,
    })
    sent++
  }
  return { sent, skipped }
}

/** Re-attempts every status='failed' outbound row through the same
 * sendMessage() choke point everything else uses — no separate retry
 * mechanism, no separate transport. Real Wasi dispatch has been wired in
 * since 2026-08-25, so a resend now genuinely can fail again — capped at
 * MAX_SEND_ATTEMPTS (shared with wa-milestone-dispatch-core's own retry
 * loop) rather than looping forever on a permanently-failing recipient
 * (2026-09-08 incident: this pass alone would have retried a 409'd send
 * once a day, indefinitely, on top of the 5-minute milestone loop doing
 * the same). retried_at doubles here as the same "no more automated
 * attempts" marker wa-milestone-dispatch-core uses, so a row this pass
 * gives up on is excluded from BOTH loops going forward, not just this
 * one. */
async function runFailedSendRetries(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ retried: number; gaveUp: number }> {
  const { data: failed, error } = await admin
    .from("whatsapp_outbox")
    .select("id, org_id, to_mobile, customer_id, template, type, payload, ref_type, ref_id, retry_count")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .eq("status", "failed")
    .is("retried_at", null)
  if (error) {
    console.error("wa-scheduled-tasks: failed-outbox query failed", error)
    errors.push(`[${orgId}] failed-outbox query failed: ${error.message}`)
    return { retried: 0, gaveUp: 0 }
  }
  let retried = 0
  let gaveUp = 0
  for (const row of failed ?? []) {
    if (!row.to_mobile) continue
    if (row.retry_count >= MAX_SEND_ATTEMPTS) {
      await notifyGaveUpOnSend(admin, row, "Follow up with them directly instead.")
      gaveUp++
      continue
    }
    const body = (row.payload as { body?: string } | null)?.body ?? ""
    await sendMessage(admin, {
      orgId,
      to: row.to_mobile,
      customerId: row.customer_id,
      template: row.template,
      body,
      type: row.type as "text" | "template" | "interactive" | "media" | undefined,
      refType: row.ref_type,
      refId: row.ref_id,
      retryCount: row.retry_count + 1,
    })
    // The retry is logged as its own new row by sendMessage (consistent
    // with every other send in this codebase never overwriting history) —
    // mark the original failed row so it stops showing up in the Failed
    // Sends list on every future pass.
    await admin.from("whatsapp_outbox").update({ status: "sent" }).eq("id", row.id)
    retried++
  }
  return { retried, gaveUp }
}

/** Supplier Monthly RFQ pipeline — Phase 2. `open_monthly_quote_requests`
 * (service_role-only RPC) does its own IST day-of-month + "already ran this
 * month" check internally via a single atomic UPDATE...WHERE (same
 * state-flip-as-lock idiom as approve_purchase_order), so this is safe to
 * call on every 5-minute tick for every org — it's a no-op except on the
 * one configured day, once. */
async function runMonthlyQuoteRequests(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ opened: number }> {
  const { data, error } = await admin.rpc("open_monthly_quote_requests", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: open_monthly_quote_requests failed", orgId, error)
    errors.push(`[${orgId}] open_monthly_quote_requests failed: ${error.message}`)
    return { opened: 0 }
  }
  return { opened: data ?? 0 }
}

/** Reliable auto-resolve for purchase_quote_requests — previously only ran
 * "on view" when an admin opened the Quotes tab, which could leave a
 * monthly batch (nobody may visit that tab for days) unresolved
 * indefinitely. `wa_resolve_purchase_quote_requests` is the service-role
 * twin of the staff-gated `resolve_purchase_quote_requests` RPC that tab
 * still calls on mount — same underlying logic, just callable without a
 * user session. Safe to call every tick: it only ever touches requests
 * whose timeout_at has already passed. */
async function runResolveQuoteRequests(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ resolved: number }> {
  const { data, error } = await admin.rpc("wa_resolve_purchase_quote_requests", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: wa_resolve_purchase_quote_requests failed", orgId, error)
    errors.push(`[${orgId}] wa_resolve_purchase_quote_requests failed: ${error.message}`)
    return { resolved: 0 }
  }
  return { resolved: data ?? 0 }
}

/** Item D5 (Rent) — the only recurring-charge mechanism in this codebase.
 * run_rental_billing (service_role-only RPC) does its own "due today or
 * earlier" filter and advances next_billing_date itself, so — same as
 * runMonthlyQuoteRequests above — it's safe to call on every tick; a
 * contract not yet due is a no-op. */
async function runRentalBilling(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ billed: number }> {
  const { data, error } = await admin.rpc("run_rental_billing", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: run_rental_billing failed", orgId, error)
    errors.push(`[${orgId}] run_rental_billing failed: ${error.message}`)
    return { billed: 0 }
  }
  return { billed: data ?? 0 }
}

/** Supplier payment-reminder tasks (auto-created on PO send, see
 * _create_po_payment_reminder_task) get a one-shot overdue escalation to
 * master 3 days past due_at. wa_escalate_overdue_po_payment_reminders is
 * idempotent per task (escalated_at guard), so it's safe to call every
 * tick — same shape as every other job in this pass. */
async function runOverduePoPaymentReminderEscalation(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ escalated: number }> {
  const { data, error } = await admin.rpc("wa_escalate_overdue_po_payment_reminders", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: wa_escalate_overdue_po_payment_reminders failed", orgId, error)
    errors.push(`[${orgId}] wa_escalate_overdue_po_payment_reminders failed: ${error.message}`)
    return { escalated: 0 }
  }
  return { escalated: data ?? 0 }
}

/** Monthly recurring tasks ("repeat monthly on this day") — advance_recurring_tasks
 * does its own "due today or earlier, no successor yet" filter and inserts
 * the next instance itself, same idiom as run_rental_billing above, so it's
 * safe to call every tick. */
async function runRecurringTaskAdvance(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ advanced: number }> {
  const { data, error } = await admin.rpc("advance_recurring_tasks", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: advance_recurring_tasks failed", orgId, error)
    errors.push(`[${orgId}] advance_recurring_tasks failed: ${error.message}`)
    return { advanced: 0 }
  }
  return { advanced: data ?? 0 }
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

  // Unconditional, every invocation, before the pacing gate below — see
  // _shared/cron-heartbeat.ts. This is the daily-cadence job, so it also
  // acts as a once-a-day cross-check on the other two jobs even if this
  // one's own interval means it's a slow heartbeat itself.
  await checkAndAlertStaleJobs(admin)

  const { data: orgs, error: orgsError } = await admin.from("organizations").select("id")
  if (orgsError) {
    await recordHeartbeat(admin, "wa_scheduled_tasks", "error", orgsError.message)
    return jsonResponse({ error: orgsError.message }, 500)
  }

  const errors: string[] = []
  const results = []
  for (const org of orgs ?? []) {
    if (!(await shouldRunJob(admin, org.id, "scheduled_tasks"))) {
      results.push({ orgId: org.id, skipped: true })
      continue
    }
    const amc = await runAmcReminders(admin, org.id, errors)
    const feedback = await runFeedbackRequests(admin, org.id, errors)
    const retries = await runFailedSendRetries(admin, org.id, errors)
    const monthlyRfq = await runMonthlyQuoteRequests(admin, org.id, errors)
    const resolvedQuotes = await runResolveQuoteRequests(admin, org.id, errors)
    const rentalBilling = await runRentalBilling(admin, org.id, errors)
    const overdueReminders = await runOverduePoPaymentReminderEscalation(admin, org.id, errors)
    const recurringTasks = await runRecurringTaskAdvance(admin, org.id, errors)
    await markJobRan(admin, org.id, "scheduled_tasks")
    results.push({ orgId: org.id, amc, feedback, retries, monthlyRfq, resolvedQuotes, rentalBilling, overdueReminders, recurringTasks })
  }

  await recordHeartbeat(admin, "wa_scheduled_tasks", errors.length > 0 ? "error" : "ok", errors.join("; "))

  // A non-2xx here (not the previous unconditional 200) is what lets
  // .github/workflows/wa-scheduled-tasks.yml's `curl --fail-with-body`
  // actually trip — GitHub's own scheduled-workflow-failure email is free
  // alerting on top of the in-app notification above — instead of every
  // per-task error being invisibly swallowed behind a 200, which is exactly
  // what the 2026-09-23 audit flagged. 500 rather than a 2xx-range 207:
  // --fail-with-body only treats >=400 as failure, and the sibling
  // wa-milestone-dispatch.yml workflow checks >=300 explicitly — 500
  // trips both.
  return jsonResponse({ ranAt: new Date().toISOString(), results, errors }, errors.length > 0 ? 500 : 200)
})
