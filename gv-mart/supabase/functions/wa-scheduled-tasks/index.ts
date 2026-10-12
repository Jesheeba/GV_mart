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
import { isDispatchV2Enabled, resolveWasiTransport, sendMessage } from "../_shared/whatsapp.ts"
import { markJobRan, shouldRunJob } from "../_shared/wa-job-pacing.ts"
import { MAX_SEND_ATTEMPTS, MILESTONE_REF_TYPES, notifyGaveUpOnSend } from "../_shared/wa-milestone-dispatch-core.ts"
import { customerLanguageAndName } from "../_shared/wa-event-context.ts"
import { mapWasiTemplateList } from "../_shared/wasi-templates.ts"
import { ALERT_TYPES, istDayStartIso, skippedAlertDue, stuckAlertDue, stuckBeforeIso } from "../_shared/wa-alerts.ts"
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
    // IST calendar date `days` from now (expiry_date is an IST-calendar date). The
    // function runs in UTC, so shift by +05:30 (no DST) before taking the date part.
    const targetDate = new Date(Date.now() + 5.5 * 3_600_000 + days * 86_400_000).toISOString().slice(0, 10)
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
      const { language } = await customerLanguageAndName(admin, contract.customer_id)
      await sendMessage(admin, {
        orgId,
        to: customer.mobile,
        customerId: contract.customer_id,
        template,
        body,
        refType: "amc_contracts",
        refId: contract.id,
        // Dispatcher v2: a system notification — approved template, or free text only inside the 24 h window.
        purpose: "notification",
        language,
        vars: { name: customer.name, customer_name: customer.name, product: product?.name ?? null, expiry_date: String(contract.expiry_date), days: String(days) },
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
    const { language } = await customerLanguageAndName(admin, ticket.customer_id)
    const appUrl = Deno.env.get("WA_PUBLIC_APP_URL")?.replace(/\/+$/, "") ?? null
    await sendMessage(admin, {
      orgId,
      to: customer.mobile,
      customerId: ticket.customer_id,
      template: "feedback_request",
      body,
      refType: "service_tickets",
      refId: ticket.id,
      purpose: "notification",
      language,
      vars: {
        name: customer.name,
        customer_name: customer.name,
        ticket_ref: ticket.id.replace(/-/g, "").slice(0, 8).toUpperCase(),
        complaint: ticket.name_of_complaint,
        rating_link: appUrl ? `${appUrl}/customer/bookings/${ticket.id}` : null,
      },
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
/** Dispatcher v2 alerts (only when the flag is on): (1) any outbound row still pending 15 minutes after it was created or
 * claimed, (2) skipped_no_template rows today above settings.wa_skipped_alert_threshold (default 10, 0 = off). Each raises ONE
 * in-app notification to the master and is not repeated while the previous one is unread; the Failed Sends tab shows the
 * same rows. Nothing is ever resent by this job. */
async function runDispatchAlerts(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ stuck: number; skippedToday: number; alerts: string[] } | { skipped: string }> {
  if (!(await isDispatchV2Enabled(admin, orgId))) return { skipped: "v2 off" }
  const nowMs = Date.now()
  const before = stuckBeforeIso(nowMs)
  const dayStart = istDayStartIso(nowMs)
  const alerts: string[] = []

  const stuckA = await admin.from("whatsapp_outbox").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("direction", "outbound").eq("status", "pending").lt("claimed_at", before)
  const stuckB = await admin.from("whatsapp_outbox").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("direction", "outbound").eq("status", "pending").is("claimed_at", null).lt("created_at", before)
  const skipped = await admin.from("whatsapp_outbox").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("status", "skipped_no_template").gte("created_at", dayStart)
  const settings = await admin.from("settings").select("wa_skipped_alert_threshold").eq("org_id", orgId).maybeSingle()
  const failure = stuckA.error ?? stuckB.error ?? skipped.error
  if (failure) {
    errors.push(`[${orgId}] dispatch alerts: ${failure.message}`)
    return { skipped: "query failed" }
  }
  const stuck = (stuckA.count ?? 0) + (stuckB.count ?? 0)
  const skippedToday = skipped.count ?? 0

  const notifyOnce = async (type: string, title: string, body: string, sinceIso: string | null) => {
    let q = admin.from("notifications").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("role", "master").eq("type", type).eq("is_read", false)
    if (sinceIso) q = q.gte("created_at", sinceIso)
    const { count } = await q
    if ((count ?? 0) > 0) return
    const { error } = await admin.from("notifications").insert({ org_id: orgId, role: "master", type, title, body })
    if (error) errors.push(`[${orgId}] dispatch alert notification: ${error.message}`)
    else alerts.push(type)
  }

  if (stuckAlertDue(stuck)) {
    await notifyOnce(ALERT_TYPES.stuck, "WhatsApp messages are stuck sending",
      `${stuck} WhatsApp message(s) have been pending for more than 15 minutes. Open Automation > Failed Sends. They are not resent automatically.`, null)
  }
  if (skippedAlertDue(skippedToday, (settings.data as { wa_skipped_alert_threshold?: number } | null)?.wa_skipped_alert_threshold)) {
    await notifyOnce(ALERT_TYPES.skipped, "Many WhatsApp messages were skipped today",
      `${skippedToday} message(s) were not sent today because no approved WhatsApp template exists for them. Open Automation > Failed Sends.`, dayStart)
  }
  return { stuck, skippedToday, alerts }
}

/** Dispatcher v2 retry pass. A failed row is the SAME row that gets another attempt (never a second row), and only a
 * failure Wasi says is transient is re-queued: 409 `conflict` (once) and a pre-send network error (up to the cap). Every
 * other failure (session_window_closed, consent_required, missing template, blocked by test mode, 502) is terminal and
 * stays in Failed Sends for a human; resending those unchanged would only fail the same way. Re-queued rows go back to
 * status 'pending' with claimed_at cleared, so the milestone dispatcher's claim-before-send picks them up. Only
 * dispatcher-owned reference types are re-queued: other rows have no loop that would send them. */
async function runFailedSendRetriesV2(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ retried: number; gaveUp: number }> {
  const { data: failed, error } = await admin
    .from("whatsapp_outbox")
    .select("id, error, retry_count, ref_type")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .eq("status", "failed")
    .is("retried_at", null)
    .in("ref_type", MILESTONE_REF_TYPES)
  if (error) {
    console.error("wa-scheduled-tasks: failed-outbox query failed (v2)", error)
    errors.push(`[${orgId}] failed-outbox query failed: ${error.message}`)
    return { retried: 0, gaveUp: 0 }
  }
  let retried = 0
  let gaveUp = 0
  for (const row of failed ?? []) {
    const text = String(row.error ?? "")
    const isConflict = text.startsWith("409: conflict")
    const isNetwork = text.startsWith("network_error")
    const cap = isConflict ? 1 : MAX_SEND_ATTEMPTS
    if (!(isConflict || isNetwork) || row.retry_count >= cap) {
      // Close it out so this pass stops selecting it; it stays visible in Failed Sends.
      await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id).is("retried_at", null)
      if (isConflict || isNetwork) gaveUp++
      continue
    }
    const { error: requeueError } = await admin
      .from("whatsapp_outbox")
      .update({ status: "pending", claimed_at: null, retry_count: row.retry_count + 1 })
      .eq("id", row.id)
      .eq("status", "failed")
    if (requeueError) errors.push(`[${orgId}] requeue failed: ${requeueError.message}`)
    else retried++
  }
  return { retried, gaveUp }
}

/** Mirrors Wasi's template list (name, language, status, header type, exact param names) into whatsapp_wasi_templates so
 * a send only uses a template that is approved, and builds its params from Wasi's own names. Read-only toward Wasi.
 * Errors count against the heartbeat only when dispatcher v2 is on (before that the table may not exist yet). */
async function runWasiTemplateSync(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ synced: number; duplicates: string[] } | { skipped: string }> {
  const v2 = await isDispatchV2Enabled(admin, orgId)
  const fail = (msg: string) => {
    console.error("wa-scheduled-tasks: wasi template sync:", msg)
    if (v2) errors.push(`[${orgId}] wasi template sync: ${msg}`)
  }
  const transport = await resolveWasiTransport(admin, orgId)
  if (!transport) return { skipped: "no transport configured" }
  let res: Response
  try {
    res = await fetch(`${transport.baseUrl}/api/v1/templates`, {
      headers: { Authorization: `Bearer ${transport.apiKey}`, "Content-Type": "application/json" },
      signal: AbortSignal.timeout(15_000),
    })
  } catch (e) {
    fail(e instanceof Error ? e.message : "request failed")
    return { skipped: "request failed" }
  }
  if (res.status !== 200) {
    fail(`GET /templates returned ${res.status}`)
    return { skipped: `http ${res.status}` }
  }
  const rows = mapWasiTemplateList(await res.json().catch(() => null))
  if (rows.length === 0) return { skipped: "empty list" }
  const { error } = await admin
    .from("whatsapp_wasi_templates")
    .upsert(rows.map((r) => ({ ...r, org_id: orgId, synced_at: new Date().toISOString() })), { onConflict: "org_id,wasi_name,language" })
  if (error) {
    fail(error.message)
    return { skipped: "upsert failed" }
  }
  const seen = new Map<string, number>()
  for (const r of rows) seen.set(r.wasi_name, (seen.get(r.wasi_name) ?? 0) + 1)
  return { synced: rows.length, duplicates: [...seen.entries()].filter(([, n]) => n > 1).map(([n]) => n) }
}

async function runFailedSendRetries(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ retried: number; gaveUp: number }> {
  if (await isDispatchV2Enabled(admin, orgId)) return runFailedSendRetriesV2(admin, orgId, errors)
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

/** Daily huddle reminder — wa_send_huddle_reminder claims the day atomically
 * (IST date + settings.huddle_reminder_time cutoff + no meeting_logs row
 * yet), so it's safe to call every tick like the other jobs here. */
async function runHuddleReminder(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ reminded: number }> {
  const { data, error } = await admin.rpc("wa_send_huddle_reminder", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: wa_send_huddle_reminder failed", orgId, error)
    errors.push(`[${orgId}] wa_send_huddle_reminder failed: ${error.message}`)
    return { reminded: 0 }
  }
  return { reminded: data ?? 0 }
}

/** Technician tier promotions — check_tier_promotion_eligibility (service_role-only
 * RPC) raises at most one pending eligibility row + one master notification
 * per technician/target tier, so it is safe to call on every tick. */
async function runTierPromotionCheck(admin: SupabaseClient, orgId: string, errors: string[]): Promise<{ flagged: number }> {
  const { data, error } = await admin.rpc("check_tier_promotion_eligibility", { p_org_id: orgId })
  if (error) {
    console.error("wa-scheduled-tasks: check_tier_promotion_eligibility failed", orgId, error)
    errors.push(`[${orgId}] check_tier_promotion_eligibility failed: ${error.message}`)
    return { flagged: 0 }
  }
  return { flagged: data ?? 0 }
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
    const templateSync = await runWasiTemplateSync(admin, org.id, errors)
    const dispatchAlerts = await runDispatchAlerts(admin, org.id, errors)
    const amc = await runAmcReminders(admin, org.id, errors)
    const feedback = await runFeedbackRequests(admin, org.id, errors)
    const retries = await runFailedSendRetries(admin, org.id, errors)
    const monthlyRfq = await runMonthlyQuoteRequests(admin, org.id, errors)
    const resolvedQuotes = await runResolveQuoteRequests(admin, org.id, errors)
    const rentalBilling = await runRentalBilling(admin, org.id, errors)
    const overdueReminders = await runOverduePoPaymentReminderEscalation(admin, org.id, errors)
    const recurringTasks = await runRecurringTaskAdvance(admin, org.id, errors)
    const huddleReminder = await runHuddleReminder(admin, org.id, errors)
    const tierPromotions = await runTierPromotionCheck(admin, org.id, errors)
    await markJobRan(admin, org.id, "scheduled_tasks")
    results.push({ orgId: org.id, templateSync, dispatchAlerts, amc, feedback, retries, monthlyRfq, resolvedQuotes, rentalBilling, overdueReminders, recurringTasks, huddleReminder, tierPromotions })
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
