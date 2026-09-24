// The actual scan-and-send logic behind the milestone-trigger bypass:
// _milestone_ticket_notify, _milestone_visit_notify, _milestone_invoice_notify
// (see 20260819170000_whatsapp_templates_and_kill_switch.sql) and
// _auto_draft_purchase_order's supplier quote-request fan-out (see
// 20260825150000_supplier_rfq_wa_automation.sql) write directly into
// whatsapp_outbox via raw SQL INSERT, never calling sendMessage() — these
// triggers structurally can't call it themselves (no pg_net in this
// project). This function finds those rows and pushes each one through the
// real sendMessage() call.
//
// Extracted out of wa-milestone-dispatch/index.ts (unchanged logic, moved
// verbatim) so it has exactly one implementation shared by two callers:
//   1. wa-milestone-dispatch itself — the GitHub Actions cron sweep across
//      every org, gated by the admin-configurable pacing in wa-job-pacing.ts.
//   2. wa-dispatch-now — an on-demand, single-org call triggered right after
//      a staff/technician/customer action writes one of these rows, so the
//      customer doesn't wait for the next cron tick. Deliberately NOT gated
//      by the same pacing (see wa-dispatch-now/index.ts) — the cron sweep
//      stays the unconditional safety net regardless of on-demand activity.
// Having one shared implementation means the double-send-prevention
// bookkeeping below (the retried_at stamp) can never drift between the two
// callers — whichever one runs first "claims" a row the same way.
import { type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { sendMessage } from "./whatsapp.ts"

export const MILESTONE_REF_TYPES = ["service_ticket", "service_visit", "invoice", "purchase_quote_request"] as const

// 2026-09-08 incident: a Wasi-side 409 for one supplier's number retried
// every 5 minutes forever (each attempt inserting a fresh failed row that
// itself was eligible for the next pass) — nothing here ever gave up. This
// caps total send attempts per logical message (tracked via
// whatsapp_outbox.retry_count, see its migration) rather than looping
// indefinitely on a permanently-failing recipient. Exported so
// wa-scheduled-tasks' own, independent failed-send retry pass (a second,
// previously equally-unbounded loop over status='failed' rows) applies the
// exact same cap and notification shape.
export const MAX_SEND_ATTEMPTS = 3

type StuckOutboxRow = {
  id: string
  org_id: string
  to_mobile: string | null
  customer_id: string | null
  template: string
  type: string | null
  payload: { body?: string } | null
  ref_type: string | null
  ref_id: string | null
  retry_count: number
}

export async function notifyGaveUpOnSend(
  admin: SupabaseClient,
  row: { id: string; org_id: string; to_mobile: string | null; template: string; ref_id: string | null },
  reason: string
) {
  console.error("wa-milestone-dispatch-core: giving up on row after", MAX_SEND_ATTEMPTS, "attempts —", reason, row.id)
  await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
  await admin.from("notifications").insert({
    org_id: row.org_id,
    role: "operation_admin",
    type: "wa_send_gave_up",
    title: "A WhatsApp message stopped retrying",
    body: `A message to ${row.to_mobile ?? "an unknown number"} (${row.template}) failed ${MAX_SEND_ATTEMPTS} times and will not be retried automatically. ${reason}`,
    ref_id: row.ref_id,
  })
}

export async function runMilestoneDispatch(
  admin: SupabaseClient,
  orgId: string
): Promise<{ dispatched: number; skippedNoBody: number; gaveUp: number; queryError?: string }> {
  const { data: rows, error } = await admin
    .from("whatsapp_outbox")
    .select("id, org_id, to_mobile, customer_id, template, type, payload, ref_type, ref_id, retry_count")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .is("wa_message_id", null)
    .is("retried_at", null)
    .in("ref_type", MILESTONE_REF_TYPES)

  if (error) {
    console.error("wa-milestone-dispatch-core: whatsapp_outbox query failed", error)
    return { dispatched: 0, skippedNoBody: 0, gaveUp: 0, queryError: error.message }
  }

  let dispatched = 0
  let skippedNoBody = 0
  let gaveUp = 0

  for (const row of (rows ?? []) as StuckOutboxRow[]) {
    const body = row.payload?.body
    // No whatsapp_templates row exists for this milestone name yet (see
    // _wa_render_template's found:false path) — there's nothing readable
    // to send. Mark retried_at anyway so this doesn't get re-checked
    // every 5 minutes forever; the real fix is adding the missing
    // template row (Automation > Templates), not fabricating content here.
    if (!body) {
      console.error("wa-milestone-dispatch-core: skipping row with no renderable body — missing template for", row.template, row.id)
      skippedNoBody++
      await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
      continue
    }
    if (!row.to_mobile) {
      console.error("wa-milestone-dispatch-core: skipping row with no to_mobile", row.id)
      await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
      continue
    }
    if (row.retry_count >= MAX_SEND_ATTEMPTS) {
      await notifyGaveUpOnSend(admin, row, "Log it manually from Purchase > Quotes or the relevant record instead.")
      gaveUp++
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
      retryCount: row.retry_count + 1,
    })
    dispatched++

    // Same bookkeeping shape as runFailedSendRetries: the real outcome
    // (sent/failed, wa_message_id, error) lives on the NEW row sendMessage()
    // just inserted, not this one — this row is only marked so it isn't
    // picked up again, by either caller (cron poll or on-demand nudge).
    await admin.from("whatsapp_outbox").update({ retried_at: new Date().toISOString() }).eq("id", row.id)
  }

  return { dispatched, skippedNoBody, gaveUp }
}
