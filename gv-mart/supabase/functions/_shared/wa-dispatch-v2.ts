// Dispatcher v2 scan loop (pure, dependency-injected so the claim race can be tested). Replaces the legacy
// "send, then stamp retried_at" loop in wa-milestone-dispatch-core.ts when settings.wa_dispatch_v2_enabled is on.
// See docs/plan-dispatcher-fix.md (c) and (e).
//
// Claim-before-send: a worker may only send a row after winning an atomic
//   UPDATE ... SET claimed_at = now() WHERE id = $1 AND status = 'pending' AND claimed_at IS NULL
// so cron and wa-dispatch-now can never both send the same row (the legacy loop stamps retried_at AFTER the send).
// There is deliberately NO automatic reclaim of a stale claim: Wasi has no idempotency key, so a resend of a message
// that was actually delivered before the worker died would double-message a customer. Stale claims are shown to a human
// in Failed Sends ("stuck sending") instead.
import { MAX_SEND_ATTEMPTS_V2 } from "./wa-send-core.ts"

export type PendingRow = {
  id: string
  org_id: string
  to_mobile: string | null
  customer_id: string | null
  template: string
  payload: { body?: string } | null
  ref_type: string | null
  ref_id: string | null
  retry_count: number
}

export type DispatchContext = { language: "en" | "ta"; vars: Record<string, string | null | undefined> }

export interface DispatchDeps {
  listPending(orgId: string): Promise<PendingRow[]>
  /** Atomic: true only for the single caller that moved claimed_at from null. */
  claim(id: string): Promise<boolean>
  failRow(id: string, patch: Record<string, unknown>): Promise<void>
  resolveContext(row: PendingRow): Promise<DispatchContext>
  send(row: PendingRow, ctx: DispatchContext): Promise<{ status: string }>
  nowIso(): string
}

export type DispatchSummary = {
  claimed: number
  sent: number
  skippedNoTemplate: number
  failed: number
  pendingAfter: number
  lostClaim: number
  noRecipient: number
}

export async function runDispatchV2(deps: DispatchDeps, orgId: string): Promise<DispatchSummary> {
  const summary: DispatchSummary = { claimed: 0, sent: 0, skippedNoTemplate: 0, failed: 0, pendingAfter: 0, lostClaim: 0, noRecipient: 0 }
  const rows = await deps.listPending(orgId)

  for (const row of rows) {
    if (row.retry_count >= MAX_SEND_ATTEMPTS_V2) {
      // Over the attempt cap: close it out visibly instead of looping. (Never claimed, so claim it to be certain
      // no other worker is mid-send, then fail it.)
      if (await deps.claim(row.id)) {
        await deps.failRow(row.id, { status: "failed", error: "gave_up_after_max_attempts", retried_at: deps.nowIso() })
        summary.failed++
      }
      continue
    }

    if (!(await deps.claim(row.id))) {
      summary.lostClaim++
      continue
    }
    summary.claimed++

    if (!row.to_mobile) {
      await deps.failRow(row.id, { status: "failed", error: "no_recipient_number", retried_at: deps.nowIso() })
      summary.noRecipient++
      continue
    }

    try {
      const ctx = await deps.resolveContext(row)
      const r = await deps.send(row, ctx)
      if (r.status === "sent") summary.sent++
      else if (r.status === "skipped_no_template") summary.skippedNoTemplate++
      else if (r.status === "failed") summary.failed++
      else summary.pendingAfter++
    } catch (e) {
      // sendMessage threw (its own DB write failed). The claim stands, so this row will not be resent automatically;
      // it shows up as a stuck claim for a human. Never print the number or a wamid.
      console.error("wa-dispatch-v2: send threw for row", row.id, e instanceof Error ? e.message : "unknown error")
      summary.pendingAfter++
    }
  }
  return summary
}
