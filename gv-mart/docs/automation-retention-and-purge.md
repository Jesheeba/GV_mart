# Automation: retention and safe purge (note, 2026-10-12)

Status: NOTE ONLY. The purge function is not built. Applies to migration `20261017100000_automation_phase2_foundation.sql` (not yet applied). Companion to `docs/plan-automation-flows.md` (on branch `docs/automation-wave1-templates`; that plan is not on this branch, so this note stands alone).

## What is kept, and for how long

| Table | What it is | Proposed retention | Why |
|---|---|---|---|
| `automation_rules` | Immutable rule versions | Forever | Tiny; needed to explain any past decision (`rule_id`, `rule_version`) |
| `automation_events`, `automation_flow_defs` | Catalogue and flow names | Forever | Configuration, not log data |
| `automation_audit` | One row per rule decision (sent/dry_run/skipped/blocked/config_changed) | **24 months** | The record of why a customer did or did not get a message; covers a complaint, a Meta/WhatsApp quality review and a full yearly comparison |
| `automation_event_log` | One row per emitted event (keys only, no values) | **13 months** | Volume driver (one row per ticket/lead/invoice change); a full year plus one month of overlap for year-on-year checks. Its decisions live on in `automation_audit` |
| `automation_queue` | Work the engine would do or did | **90 days** after the row reaches a terminal state (today: every row, since all are `dry_run` or `blocked_not_allowlisted`) | Operational; once delivered or dead it is only needed for idempotency within the cooldown and max-fires windows (the longest rule window is 90 days for review cooldown) |
| `automation_errors` | Trigger/engine failures, no personal data | **90 days** | Diagnostic only; recurring errors are visible within weeks |

Rules for these numbers:
- A retention period must never be shorter than the longest dedupe, cooldown or max-fires window of any rule, because the queue is the idempotency record. Phase 2 has a 90-day review cooldown as the longest planned window, so 90 days is the floor for `automation_queue`.
- Test rows (`is_test = true`) can be purged on a shorter schedule (30 days) once the test harness exists; they carry no customer value.
- None of these tables stores a full phone number, message body, or payload value (masked last four digits and key names only), so retention is not driven by personal-data minimisation, only by usefulness and size.
- These are proposals for the owner to confirm; the existing `audit_log` table keeps its own, separate policy.

## Size expectation

Rows are small (about 150 to 300 bytes plus indexes). At a few hundred business events per day and a handful of rules per event, the log grows by tens of thousands of rows per month, i.e. well under 100 MB per year for `automation_event_log` plus `automation_audit`. Partitioning by month is only worth adding if a table passes a few million rows.

## Why a plain DELETE does not work (and must not be made to)

`automation_event_log`, `automation_audit` and `automation_errors` carry a `BEFORE UPDATE OR DELETE` trigger and a `BEFORE TRUNCATE` trigger that refuse every change, including from the service role, exactly like `audit_log` (migration `20261011110000`). The trigger has one narrow door: a DELETE run by the owner role (`postgres`) while the transaction-local flag `app.audit_purge_ok = '1'` is set, which is how `purge_test_organisation()` removes a test organisation. `automation_rules` is immutable and also refuses DELETE except through the same door. `automation_queue` is not append-only (it is operational) but has no client write path.

A direct `delete from automation_audit where ...` therefore fails, by design. Retention must go through one controlled function.

## Safe purge approach (design, not built)

One `SECURITY DEFINER` function, owned by `postgres`, `search_path` fixed, EXECUTE revoked from PUBLIC, anon and authenticated and granted to `service_role` only (so no signed-in user can call it, and it appears on no client surface):

```
automation_purge(p_dry_run boolean default true, p_batch integer default 5000)
```

Behaviour:
1. **Dry run by default.** Returns counts per table of what would go, deletes nothing. A real run needs `p_dry_run := false`.
2. **Fixed cut-offs inside the function**, not passed by the caller (so a typo cannot wipe the history): event_log older than 13 months, audit older than 24 months, errors and terminal queue rows older than 90 days. Constants live in one place and are covered by the test.
3. **Order matters:** queue and errors first, then audit, then event_log, so no audit row ever outlives the event it explains by design (the reverse is acceptable; an audit row without its event is still self-describing).
4. **Never touches** `automation_rules`, the catalogue, or any row newer than the cut-off; never touches `is_current` rules or a queue row that is still inside a cooldown or max-fires window.
5. **Sets the flag only inside the function:** `set_config('app.audit_purge_ok', '1', true)` for the transaction, deletes in batches (`limit p_batch`, loop with a bounded iteration count), and resets it before returning. The flag cannot leak to the caller's session because it is transaction-local.
6. **Leaves its own trace:** writes one `audit_log` row (action `AUTOMATION_PURGE`, table counts, cut-off dates, caller) per real run, so the purge itself is auditable and append-only.
7. **Scheduled** with `pg_cron` monthly, off-hours, using the dry run first in the log. Failures go to the existing cron heartbeat/dead-man alerting, not silent.
8. **Tests required before it ships** (rolled back, like the Phase 2 tests): dry run deletes nothing; real run deletes only rows older than each cut-off and keeps newer ones; rules and catalogue untouched; a queue row inside a cooldown window survives; the flag is not set after the call; a direct DELETE still fails afterwards; anon, authenticated and every staff role cannot execute it; service_role can; an `audit_log` row is written.

Not built in this phase because the first rows will not reach the oldest cut-off (13 months) for over a year, so there is nothing to purge yet; the function and its tests should ship with Phase 5 or earlier if volume grows faster than expected.

## Related

- Test organisations are still removed only through `purge_test_organisation()`; the automation tables cascade from `organizations` and use the same `app.audit_purge_ok` door.
- Deleting a profile does not break rule immutability: `automation_rules.created_by` is allowed to go to NULL when its author's profile no longer exists (tested).
