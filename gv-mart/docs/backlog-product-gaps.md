# Product backlog: gaps found in operation

Specification only. Nothing here is built. Recorded 2026-10-14.

## Gap A: an AMC contract cannot be cancelled from the app (priority: high)

**Found:** 2026-10-13/14, test contract e13bcc7c. The owner cancelled "in the app" and nothing persisted on the contract.

**Cause:** the database function `cancel_amc_contract(p_contract_id, p_reason)` exists (master only, reason required, cancels the
open visits and appointments, marks the contract cancelled) but no screen calls it. The only cancel the app offers is per ticket,
which leaves the contract active and its other visits alive.

**Specification**
- Master only. Hidden for every other role. The server already enforces this; the UI must not offer it to anyone else.
- A "Cancel contract" action on the AMC contract detail view.
- A required reason (free text, not blank), passed as `p_reason`.
- A confirm step before anything is sent. The dialog states, from live counts, what will be cancelled: the number of visits that
  will be cancelled, the number kept (completed / in progress), the number of appointments affected, and that assigned technicians
  will be released. It states clearly that this cannot be undone and that gift stock and any money are NOT reversed automatically.
- After success, show the returned `visits_cancelled` and `visits_kept`.
- Not in scope for the first version: refund, gift-stock restore (see "Open design question" below).

**Open design question:** whether cancelling should also restore reserved gift stock. Today it does not, so the test contract
needed a separate manual +1 stock adjustment.

**Open design question (status):** the function sets `amc_contracts.status = 'expired'` on cancellation, not 'cancelled'. A cancelled
contract therefore reads as "expired" in the UI and in reports, with only `cancelled_at` set to show otherwise. Someone reconciling
contracts later cannot tell a cancellation from a natural expiry without checking `cancelled_at`. Decide: should a cancelled
contract show as cancelled (a distinct status or label)?

**Open design question (actor):** a master session is required, so any out-of-band run must impersonate a master and the audit
rows name that master. Consider a service-level or "on behalf of" path that records the true actor.

## Gap B: cancellation errors surface as a generic toast (priority: medium)

**Found:** same incident. A failing cancel showed only `common.actionFailed`, so the owner could not tell whether it worked.

**Specification**
- Any mutation that the database rejects must show the database's own message (for example "contract already cancelled",
  "reason is required", "master role required"), not the generic `common.actionFailed` string.
- Keep the generic string only as the fallback when no message is available.
- Applies first to ticket cancel and contract cancel, then to the other destructive actions.
- Success and failure must be distinguishable: no success toast unless the call returned without error.

## Gap C: stale notifications and no "visit cancelled" notice (priority: medium)

**Found:** 2026-10-14, while cleaning up test contract e13bcc7c.

- Notifications are plain cards with no link to the ticket or appointment (admin and technician pages show title, body, timestamp,
  mark-read). Opening one leads nowhere, so there is no broken view, but also nothing that says the visit is no longer happening.
- After a contract or ticket is cancelled, earlier "New job assigned" / "Ticket auto-assigned" / "AMC plan sold" notifications stay
  unread and keep their original wording.
- `cancel_amc_contract` (and ticket cancel) writes no notification to the assigned technician. A technician who was told about a
  visit is never told it was cancelled, which is how they end up unsure whether it is still on.

**Specification**
- When a visit or ticket is cancelled and a technician had been assigned, send that technician an in-app "visit cancelled"
  notification (and, if the owner approves, WhatsApp through the normal dispatcher).
- On cancellation, mark that ticket's earlier assignment notifications read (the function already does this for
  `ticket_unassigned` only).
- Make notification cards link to the ticket/appointment, with a "cancelled" state shown when it is no longer live.

**Rule for Gap C:** on cancellation the technician must be TOLD (a new "visit cancelled" notice). Marking the old assignment
notification read is not a substitute for that. They are two different things; conflating them is how someone drives to a
cancelled visit.

## Security: link_customer_google_account account-takeover exposure: CLOSED 2026-10-14

- **Closed by** migration 20261021100000 `revoke_link_customer_google_account`, applied live 2026-10-14
  (`revoke execute ... from public, anon, authenticated`).
- **Live grants now (read back 2026-10-14):** ACL `{postgres=X/postgres, service_role=X/postgres}`. EXECUTE: postgres yes,
  service_role yes, authenticated NO, anon NO.
- **Rollback:** `supabase/rollbacks/20261021100000_revoke_link_customer_google_account.rollback.sql` (one GRANT restoring the
  previous ACL; re-opens the hole, so do not run it casually). Source commit 4e5a4c0, branch `fix/revoke-link-customer-google-account`.
- **Nothing legitimate broke:** the only caller is `GoogleLinkAccountCard` (via `linkCustomerGoogleAccount` in `src/services/auth.ts`),
  reachable only after a first-time Google sign-in; Google login is off, so the card cannot be reached today.
- **No customer notification, reasoning:** exposure was possible but there is no evidence of use in any readable source; the audit
  footprint the function leaves never appeared; no mobile exists in more than one organisation; and the window was closed the day it
  was found. Limit stated: failed attempts are unknowable. Full record: `docs/security-link-customer-account.md` on that branch.
- **Still open:** the replacement (decided 2026-10-14: option 1b, Supabase phone verification with the Send SMS hook over WhatsApp;
  spec `docs/spec-link-customer-login-phone-otp.md` on that branch, awaiting owner security review) is specified, not built, and must exist before Google login is switched on
  (until then the link card would fail with permission denied). Open question: should public sign-up be open at all.

## Cleanup: unseeded test organisation `__TEST_ GV Mart 2026-10-12`

**Found:** 2026-10-23, while investigating `20261008100000_reseed_complaint_types.sql` (see that migration's deletion note in the
Monthly Expenses feature history — the review found the premise unsupported and removed it rather than holding it).

- Organisation `8b87c496-de26-4539-8fc8-3f3e7056d3c3`, created 2026-10-12, has zero `complaint_types` rows and is otherwise
  unseeded — it is missing all 71 rows a normal organisation would have.
- Not touched, not deleted, by that review — read-only investigation only.
- Needs its own decision: either seed it properly if it is still in use for testing, or remove it if it is a leftover that should
  not be sitting in production.
