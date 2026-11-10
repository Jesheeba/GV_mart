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
import { getDispatchV2Scope, sendMessage } from "./whatsapp.ts"
import { v2Active, v2AppliesTo, type DispatchV2Scope } from "./wa-dispatch-scope.ts"
import { runDispatchV2, type DispatchDeps, type PendingRow } from "./wa-dispatch-v2.ts"
import { resolveEventContext } from "./wa-event-context.ts"

// 'customer_link_otp' added 2026-11-20 (OTP-verified customer Google account linking,
// docs/backlog-product-gaps.md): request_customer_link_code() writes a row with this ref_type
// directly into whatsapp_outbox (status 'pending'), the same way the milestone triggers above
// already do — no new send path, this function is the one that was already picking those up.
export const MILESTONE_REF_TYPES = ["service_ticket", "service_visit", "invoice", "purchase_quote_request", "customer_link_otp"] as const

// Ref types whose payload.body contains a secret (the OTP code itself) that must not sit in
// plaintext in whatsapp_outbox any longer than it has to — any staff/master user can read that
// table via whatsapp_outbox_select_staff (20260702170000_automation_purchase_schema.sql). Once a
// send genuinely succeeds, the body has done its job and is redacted in place. See
// DECISIONS.md section 5 in the customer-OTP-link branch: this redaction only runs in the v2
// dispatch path below (runMilestoneDispatchV2), because that is the one place this scan loop
// updates a row BY THE SAME id it sent with (outboxId) — the legacy path inserts a fresh row
// per attempt via sendMessage()'s own stub/legacy insert and isn't safe to retrofit here without
// risking every other milestone type that path also serves. If settings.wa_dispatch_v2_enabled
// is off for an org, this redaction does not happen — recorded as a residual, documented
// exposure, not a silent gap.
const REDACT_BODY_AFTER_SEND_REF_TYPES = new Set<string>(["customer_link_otp"])

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
  payload: { body?: string; code?: string } | null
  ref_type: string | null
  ref_id: string | null
  retry_count: number
}

// customer_link_otp only (phase 2, Item 2): the challenge this outbox row is FOR may have
// expired, been used, or been superseded by a newer request by the time either dispatch path
// (the fast pg_net-triggered one, or this cron sweep as its fallback) actually gets to send it --
// the 10-minute expiry clock races against both. Sending a stale code is not itself exploitable
// (verify_customer_link_code's own expires_at/used_at checks already refuse it either way) but it
// would hand the customer a dead code and keep the plaintext body/code alive in whatsapp_outbox
// for no reason, so this is checked immediately before ever calling sendMessage, on BOTH the v2
// and legacy paths below. Returns true (a true no-op, no query) for every ref_type except
// customer_link_otp -- this must never become a general staleness check for other message types.
// Returns null when the row is still sendable, otherwise the reason it must NOT be sent (used as
// whatsapp_outbox.error so a disabled-flag refusal is never mislabeled as an expired/used code in
// data ops later reads to debug "why did sends stop?" -- independent-review LOW finding).
async function customerLinkOtpUnsendableReason(admin: SupabaseClient, refType: string | null, refId: string | null): Promise<string | null> {
  if (refType !== "customer_link_otp" || !refId) return null

  // Dispatch-time re-check of the feature flag itself, not just this row's own staleness.
  // Independent-review LOW/INFO finding (DECISIONS.md): is_customer_link_otp_enabled() was only
  // ever checked once, at REQUEST time (request_customer_link_code), never re-checked when the
  // message is actually dispatched -- an admin flipping customer_link_otp_settings.enabled or
  // settings.wa_dispatch_v2_enabled/scope off between request and dispatch could let an
  // already-enqueued row fall through to send anyway. Same fail-open-on-transient-error,
  // fail-closed-on-explicit-false philosophy as the staleness check below: a flaky RPC call must
  // never silently block a real, still-valid code, but an explicit "disabled" answer must stop it.
  const { data: enabled, error: enabledError } = await admin.rpc("is_customer_link_otp_enabled")
  if (enabledError) {
    console.error("wa-milestone-dispatch-core: is_customer_link_otp_enabled re-check failed, sending anyway", enabledError.message)
  } else if (enabled === false) {
    return "customer_link_otp_disabled_at_dispatch"
  }

  const { data, error } = await admin
    .from("customer_link_otp_challenges")
    .select("expires_at, used_at, superseded_at")
    .eq("id", refId)
    .maybeSingle()
  if (error) {
    // Fail OPEN, not closed: a transient lookup error must never silently block a real,
    // still-valid code from ever being sent (worse than the rare case of sending one that turned
    // stale in the last few seconds, which verify_customer_link_code refuses anyway).
    console.error("wa-milestone-dispatch-core: customer_link_otp_challenges lookup failed, sending anyway", error.message)
    return null
  }
  const challenge = data as { expires_at: string; used_at: string | null; superseded_at: string | null } | null
  if (!challenge) return null // row missing -- nothing to gate on; the existing no-body/no-recipient checks handle an otherwise-broken row
  if (challenge.used_at || challenge.superseded_at) return "otp_expired_or_used"
  return new Date(challenge.expires_at).getTime() > Date.now() ? null : "otp_expired_or_used"
}

export async function notifyGaveUpOnSend(
  admin: SupabaseClient,
  row: { id: string; org_id: string; to_mobile: string | null; template: string; ref_id: string | null; ref_type?: string | null },
  reason: string
) {
  console.error("wa-milestone-dispatch-core: giving up on row after", MAX_SEND_ATTEMPTS, "attempts —", reason, row.id)
  // SECURITY REVIEW FINDING (independent adversarial review, 2026-11-20, MEDIUM): redaction after
  // a successful send (REDACT_BODY_AFTER_SEND_REF_TYPES, above) only fires on status 'sent' — a
  // row that permanently exhausts MAX_SEND_ATTEMPTS and ends up here instead previously kept its
  // plaintext body (the OTP code, for customer_link_otp rows) in whatsapp_outbox forever, long
  // past the challenge's own 10-minute expiry, readable by any staff/master. Redact the same way
  // on give-up, not just on send — the content was never delivered either way, so there is
  // nothing lost by clearing it here too.
  const patch: Record<string, unknown> = { retried_at: new Date().toISOString() }
  if (row.ref_type && REDACT_BODY_AFTER_SEND_REF_TYPES.has(row.ref_type)) {
    patch.payload = { body: "[redacted after gave up retrying]" }
  }
  await admin.from("whatsapp_outbox").update(patch).eq("id", row.id)
  await admin.from("notifications").insert({
    org_id: row.org_id,
    role: "operation_admin",
    type: "wa_send_gave_up",
    title: "A WhatsApp message stopped retrying",
    body: `A message to ${row.to_mobile ?? "an unknown number"} (${row.template}) failed ${MAX_SEND_ATTEMPTS} times and will not be retried automatically. ${reason}`,
    ref_id: row.ref_id,
  })
}

/** Dispatcher v2 (settings.wa_dispatch_v2_enabled): claim-before-send over status='pending' rows, update in place.
 * See _shared/wa-dispatch-v2.ts and docs/plan-dispatcher-fix.md. */
async function runMilestoneDispatchV2(
  admin: SupabaseClient,
  orgId: string,
  scope: DispatchV2Scope,
  refTypes: readonly string[]
): Promise<{ dispatched: number; skippedNoBody: number; gaveUp: number; queryError?: string }> {
  const deps: DispatchDeps = {
    async listPending(org) {
      const { data, error } = await admin
        .from("whatsapp_outbox")
        .select("id, org_id, to_mobile, customer_id, template, payload, ref_type, ref_id, retry_count")
        .eq("org_id", org)
        .eq("direction", "outbound")
        .eq("status", "pending")
        .is("claimed_at", null)
        .in("ref_type", refTypes)
        .order("created_at", { ascending: true })
        .limit(100)
      if (error) throw error
      // only the recipients v2 applies to; everyone else is handled by the legacy half of the dispatcher
      return ((data ?? []) as PendingRow[]).filter((r) => v2AppliesTo(scope, r.to_mobile))
    },
    async claim(id) {
      const { data, error } = await admin
        .from("whatsapp_outbox")
        .update({ claimed_at: new Date().toISOString() })
        .eq("id", id)
        .eq("status", "pending")
        .is("claimed_at", null)
        .select("id")
      if (error) throw error
      return (data ?? []).length === 1
    },
    async failRow(id, patch) {
      const { error } = await admin.from("whatsapp_outbox").update(patch).eq("id", id)
      if (error) throw error
    },
    resolveContext: (row) => resolveEventContext(admin, row),
    async send(row, ctx) {
      const unsendableReason = await customerLinkOtpUnsendableReason(admin, row.ref_type, row.ref_id)
      if (unsendableReason) {
        await admin
          .from("whatsapp_outbox")
          .update({ status: "failed", error: unsendableReason, payload: { body: "[redacted after otp expired/used]" } })
          .eq("id", row.id)
          .then(
            () => {},
            (e) => console.error("wa-milestone-dispatch-core: expired/used-otp mark failed for", row.id, e)
          )
        return { status: "failed" }
      }
      const r = await sendMessage(admin, {
        orgId: row.org_id,
        to: row.to_mobile as string,
        customerId: row.customer_id,
        template: row.template,
        body: row.payload?.body ?? "",
        refType: row.ref_type,
        refId: row.ref_id,
        retryCount: row.retry_count,
        purpose: "notification",
        language: ctx.language,
        vars: ctx.vars,
        outboxId: row.id,
      })
      const status = r.status ?? (r.dispatched ? "sent" : "pending")
      if (status === "sent" && row.ref_type && REDACT_BODY_AFTER_SEND_REF_TYPES.has(row.ref_type)) {
        // Best-effort: a failure here just leaves the code visible a little longer, it must
        // never undo or fail the send itself, which has already happened.
        await admin.from("whatsapp_outbox").update({ payload: { body: "[redacted after send]" } }).eq("id", row.id).then(
          () => {},
          (e) => console.error("wa-milestone-dispatch-core: post-send redaction failed for", row.id, e)
        )
      }
      return { status }
    },
    nowIso: () => new Date().toISOString(),
  }
  try {
    const s = await runDispatchV2(deps, orgId)
    return { dispatched: s.sent, skippedNoBody: s.skippedNoTemplate, gaveUp: s.failed }
  } catch (e) {
    console.error("wa-milestone-dispatch-core: v2 scan failed", e instanceof Error ? e.message : "unknown error")
    return { dispatched: 0, skippedNoBody: 0, gaveUp: 0, queryError: e instanceof Error ? e.message : "scan failed" }
  }
}

export async function runMilestoneDispatch(
  admin: SupabaseClient,
  orgId: string,
  // Phase 2, Item 2 (fast OTP dispatch path): optional override of which ref_types this scan
  // covers. Every EXISTING caller (wa-milestone-dispatch's cron sweep, wa-dispatch-now's
  // on-demand nudge) omits this and keeps scanning the full MILESTONE_REF_TYPES list, completely
  // unchanged. Only the new wa-otp-dispatch/index.ts passes a locked-down
  // `{ refTypes: ["customer_link_otp"] }` — and that value is hardcoded there, not caller-
  // supplied over HTTP, so this parameter existing at all does not create a way for anything
  // reachable from outside this codebase to widen or narrow the cron/on-demand scan's own scope.
  opts?: { refTypes?: readonly string[] }
): Promise<{ dispatched: number; skippedNoBody: number; gaveUp: number; queryError?: string }> {
  const refTypes = opts?.refTypes ?? MILESTONE_REF_TYPES
  const scope = await getDispatchV2Scope(admin, orgId)
  if (!v2Active(scope)) return runLegacyMilestoneDispatch(admin, orgId, null, refTypes)
  const v2 = await runMilestoneDispatchV2(admin, orgId, scope, refTypes)
  if (scope.scope === "org") return v2
  // scope "numbers": the listed recipients went through v2 above; everyone else stays on the legacy loop exactly as before
  const legacy = await runLegacyMilestoneDispatch(admin, orgId, scope, refTypes)
  return {
    dispatched: v2.dispatched + legacy.dispatched,
    skippedNoBody: v2.skippedNoBody + legacy.skippedNoBody,
    gaveUp: v2.gaveUp + legacy.gaveUp,
    queryError: v2.queryError ?? legacy.queryError,
  }
}

/** The pre-v2 loop, unchanged. `scope` is null when v2 is off. In partial mode (scope "numbers") it leaves v2 rows alone:
 * status pending, and any recipient v2 applies to. */
async function runLegacyMilestoneDispatch(
  admin: SupabaseClient,
  orgId: string,
  scope: DispatchV2Scope | null,
  refTypes: readonly string[]
): Promise<{ dispatched: number; skippedNoBody: number; gaveUp: number; queryError?: string }> {
  let query = admin
    .from("whatsapp_outbox")
    .select("id, org_id, to_mobile, customer_id, template, type, payload, ref_type, ref_id, retry_count")
    .eq("org_id", orgId)
    .eq("direction", "outbound")
    .is("wa_message_id", null)
    .is("retried_at", null)
    .in("ref_type", refTypes)
  if (scope) query = query.neq("status", "pending")
  const { data: rows, error } = await query

  if (error) {
    console.error("wa-milestone-dispatch-core: whatsapp_outbox query failed", error)
    return { dispatched: 0, skippedNoBody: 0, gaveUp: 0, queryError: error.message }
  }

  let dispatched = 0
  let skippedNoBody = 0
  let gaveUp = 0

  for (const row of (rows ?? []) as StuckOutboxRow[]) {
    if (scope && v2AppliesTo(scope, row.to_mobile)) continue // v2 owns this recipient
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

    const legacyUnsendableReason = await customerLinkOtpUnsendableReason(admin, row.ref_type, row.ref_id)
    if (legacyUnsendableReason) {
      console.error("wa-milestone-dispatch-core: skipping customer_link_otp row,", legacyUnsendableReason, row.id)
      await admin
        .from("whatsapp_outbox")
        .update({ retried_at: new Date().toISOString(), status: "failed", error: legacyUnsendableReason, payload: { body: "[redacted after otp expired/used]" } })
        .eq("id", row.id)
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
