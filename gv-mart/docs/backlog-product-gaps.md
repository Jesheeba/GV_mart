# Product backlog: gaps found in operation

Specification only. Nothing here is built. Recorded 2026-10-14.

## PATTERN (above the individual fixes): work is given to a person and nothing ever takes it back

Three instances in one week, all the same shape: work is assigned to a technician, the assignment is later wrong, and no process
withdraws it or tells the person.

1. The cancelled test contract's six appointments sat on one technician after the contract was cancelled (Gap A).
2. A cancellation sends the technician no notice and leaves the old "New job assigned" unread (Gap C).
3. AMC visits assigned at sale (migration 20261022100000) are never re-checked if the technician is deactivated, goes on leave or
   becomes unavailable, because the daily job only looks at UNASSIGNED visits.

**Rule to design against:** every place that assigns work to a person needs a defined way to take it back and tell them: when the
work is cancelled, when the person becomes unavailable, and when it is reassigned. Assignment without a release path is not finished.
Review every assignment path (tickets, AMC visits, tasks, leads) against this rule.

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

## Visit dates: two known gaps (not blockers; decision 2026-10-14)

- Roll-forward via `_visit_working_day` is accepted. Gap 1: confirm whether `_lead_is_working_day` consults any public-holiday
  calendar. Today it is a weekday list from settings, so a public holiday probably lands on the day.
- Gap 2: there is no mechanism for "the customer cannot do that date" (no customer-side date choice or advance confirmation). Staff
  can reschedule a visit by hand afterwards.

## AMC back-dated sales (decision 2026-10-14: refuse beyond a threshold unless a master confirms, plus visibility): BUILT, ACCEPTED, NOT APPLIED

- Threshold: `settings.amc_backdate_max_days`, default 7, range 0..90.
- Beyond it, `sell_amc_plan` raises `AMC_BACKDATED` unless `p_confirm_backdated = true` AND the caller is a master.
- Inside it: skipped visit numbers stored on `amc_contracts.visits_skipped`, master notification `amc_visits_skipped`, response lists
  each skipped visit with the date it would have been on, and the Sell AMC panel shows them and requires acknowledgement.
- The term is NOT shifted (a different contract is a commercial conversation).

## AMC visit release path: SEPARATE FOLLOW-UP MIGRATION, QUEUED AHEAD OF THE ENQUIRY WORK, NOT BUILT

**Status (owner decision):** this is a separate follow-up migration, not part of 20261022100000. Do not build yet. Kept in the
queue ahead of the enquiry work.

**Problem:** visits inside the window are assigned at sale. If the technician is later deactivated, on leave or unavailable, nothing
reassigns the visit, because `assign_due_amc_visits` only selects unassigned visits.

**Specification** (extend `assign_due_amc_visits`, same daily 06:30 IST run):
1. Select AMC visit tickets (contract_id not null, type amc, status open/assigned) with a future scheduled appointment whose
   technician is now: inactive (`technicians.is_active = false`), on leave on that date, or at capacity for that date.
2. For each, in its own sub-transaction (one failure never stops the rest): clear the technician on the appointment, set the ticket
   back to open, clear assigned_at and SLA, **notify the old technician that the visit is withdrawn** (a notice, not just a read
   mark), then run the same engine to reassign; if nobody is free, the normal "needs manual assignment" alert fires once.
3. Idempotent: a visit already released/reassigned is not touched again; report counts in the heartbeat row.
4. Optionally also fire on `technicians.is_active -> false` so it does not wait for the next morning.

**Size:** one function change of roughly 80-120 lines of SQL plus about 10 rolled-back tests (inactive, on leave, capacity, none
free, idempotent, failure isolation, notice written, in-progress visit left alone). No UI. About half a day to a day including
tests. Open exposure until it ships: a visit assigned at sale to a technician who then leaves is not taken back for up to the
window (7 days).

## Queue order for the automation work (owner, 2026-10-14). Nothing here is built; no migration is applied without the owner naming it

Status of the AMC visits migration (20261022100000): approved in text only; the "GO APPLY" instruction was WITHDRAWN on 2026-10-14,
so nothing waits for it. It is under owner review (file, sha256 and the delta against the reviewed text were posted in chat).

Build order, each item a separate migration where it touches the database, each with tests, a branch and a report; migration text is
posted for review first; no apply and no push without the owner naming it:

0. **AMC visit release path (decision 3)**, a separate follow-up migration, AHEAD of everything below. Specification: the section
   "AMC visit release path" above (extend `assign_due_amc_visits`; withdraw and notify, then reassign).
1. `enquiry.item_added` event and the per-item cooldown: `item_key`, `cooldown_per_item`, and the lead payload fields `product_id`,
   `spare_id`, `has_item`, `item_key`. Spec: `docs/automations-flows-design.md` at ab9f54b (branch `docs/automations-flows-design`).
2. Emit refuses a rule with no customer record, as `skipped_no_recipient` / `no_customer_record`, for EVERY customer rule. The Phase 2
   and Phase 3A tests are re-run only inside a transaction the builder opens and rolls back itself.
3. Enquiry-video resolver, the lead hand-off type and `skipped_no_video`, per the same spec including its language-column section.
4. LATER: WhatsApp bot item capture from a product list.

Standing rules for all of the above: no database write unless the owner names it in the chat; never concatenate a migration with a test
file against the live database; do not re-run anything "to check" without asking.

## Follow-up: friendly "in use" message for spares that have videos (2026-10-14, from feat/video-language)

**Status:** not built. Small, no database change beyond one function body.

**Problem:** `spare_videos.spare_id` is `ON DELETE NO ACTION`, so deleting a spare that still has videos is refused by the database. The
Masters > Spares delete check uses `spare_has_references`, which does not know about `spare_videos`, so the admin sees the raw
foreign-key error instead of the usual "in use" message.

**Fix:** add `exists (select 1 from public.spare_videos where spare_id = p_id)` to `spare_has_references` (migration
`20260923100100_inventory_reference_check_functions.sql` is its latest definition on main; other branches redefine it, so build it
on the merged function, not on a stale copy), and add `spare_videos` to any spare soft-delete reference list that mirrors it.
Alternatively check `spare_videos` client-side in `SparesTab` `checkCanDelete` as a stop-gap. One rolled-back test: a spare with a
video reports in use, and without one does not. Builds after the migration `20261023100000_video_language` is applied.

## Follow-up: Customers quick-filter counts don't exclude test customers consistently (2026-10-24, from the Customers-list speed-up)

**Status:** not fixed. Explicitly deferred by the owner during review of migration `20261024170000_customer_filter_counts_sql`;
do not fix without the owner naming it.

**Problem:** `customer_filter_counts()` (`20261024170000_customer_filter_counts_sql.sql`) computes four numbers for the Customers
screen's quick-filter chip row: `total`, `hasAmc`, `amcDueSoon`, `dormant`. Only `total` excludes `is_test = true` customers
(`where org_id = v_org and is_test = false`). `hasAmc`, `amcDueSoon`, and `dormant` count every matching `amc_contracts`/`customers`
row for the org regardless of `is_test`, so a flagged test customer with an AMC contract (or sitting dormant) is counted in those
three chip numbers but excluded from `total`.

**Not introduced by this migration:** this is a straight port of the pre-existing client-side behavior
(`idsWithAmc` / `idsByAmcStatus` / `idsDormant` in `src/services/customers.ts`, now removed) — the same asymmetry existed before
20261024170000 and was reproduced faithfully rather than silently fixed during the performance change, per the "ADDITIVE ONLY,
no behavior change beyond performance" scope that migration was reviewed under.

**If/when addressed:** join `amc_contracts`/`customers` against `customers.is_test = false` for all three counts, matching `total`'s
existing filter. Small, additive change to `customer_filter_counts()`'s body only — no schema change.
