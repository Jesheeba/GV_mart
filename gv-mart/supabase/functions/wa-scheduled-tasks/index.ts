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

async function runAmcReminders(admin: SupabaseClient, orgId: string): Promise<{ sent: number; skipped: number }> {
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

async function runFeedbackRequests(admin: SupabaseClient, orgId: string): Promise<{ sent: number; skipped: number }> {
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
 * mechanism, no separate transport. With the transport still stub/log-only
 * (decision #5), a resend always "succeeds" (logs again); once a real
 * provider is wired in, this same pass starts doing genuine retries with
 * no code change here. */
async function runFailedSendRetries(admin: SupabaseClient, orgId: string): Promise<{ retried: number }> {
  const { data: failed, error } = await admin
    .from("whatsapp_outbox")
    .select("id, to_mobile, customer_id, template, type, payload, ref_type, ref_id")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .eq("status", "failed")
  if (error) {
    console.error("wa-scheduled-tasks: failed-outbox query failed", error)
    return { retried: 0 }
  }
  let retried = 0
  for (const row of failed ?? []) {
    if (!row.to_mobile) continue
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
    })
    // The retry is logged as its own new row by sendMessage (consistent
    // with every other send in this codebase never overwriting history) —
    // mark the original failed row so it stops showing up in the Failed
    // Sends list on every future pass.
    await admin.from("whatsapp_outbox").update({ status: "sent" }).eq("id", row.id)
    retried++
  }
  return { retried }
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
    const amc = await runAmcReminders(admin, org.id)
    const feedback = await runFeedbackRequests(admin, org.id)
    const retries = await runFailedSendRetries(admin, org.id)
    results.push({ orgId: org.id, amc, feedback, retries })
  }

  return jsonResponse({ ranAt: new Date().toISOString(), results })
})
