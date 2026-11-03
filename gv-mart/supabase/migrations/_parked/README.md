# Parked migrations

These migration files must **never** be applied. Each is superseded by
`20261202120000_complaint_daybump_fix_and_technician_pick_merged.sql`, which
contains both fixes in one correct body built on the live function.

- `20261201100100_fix_complaint_appointment_silent_next_day_bump.sql` (urgent
  item #4) — the day-bump control-flow fix, written against the body that
  was live at the time.
- `20261202090000_complaint_explicit_technician_assignment.sql` (urgent item
  #1) — the `p_technician_id` addition, written against the **pre-#4** body
  (it still contains the buggy retry-loop lines `_create_complaint_ticket_internal`
  had before #4's fix). Applying this after #4 would have silently reverted
  #4's fix via `CREATE OR REPLACE`.

Parked here on 2026-11-02 instead of deleted, so the history of what was
tried and why is not lost. See `gv-mart/DECISIONS.md` for the decision
record. The repo's migration runner must not pick up files under this
`_parked/` subfolder — if it ever does, that is itself a bug to fix before
relying on this folder as a safe parking spot.

- `20261204120000_customer_dedupe_advisory_lock_rebased.sql` (+ its
  `.apply.sql`, `.apply.sql.out.txt`, `.rollback.sql`) — parked 2026-11-03
  during the clean-address-form redesign work. Still marked "NOT APPLIED"
  in its own header and never approved, but it redefines
  `create_customer_with_details` against a **stale pin**: a body copied
  from the live function as read on 2026-11-02, before
  `20261103091000_fix_create_customer_with_details_overload.sql` fixed the
  real (6-arg) function to insert `full_address` instead of
  `door_no`/`building_no`/`building_name`/`plot_no`/`street_cross`/`landmark`.
  If this were ever applied as committed, `create or replace` would
  silently revert the live function back to the old door_no-based address
  contract and full_address would stop being written by every new-customer
  creation — breaking the clean-address-form redesign
  (`20261103090000_address_full_address_field.sql` and this stream's own
  `sub_area` work) without any error, since the signature still matches.
  Its `.apply.sql` does have a live drift guard (sha256 pin check on
  `create_customer_with_details`/`move_lead_to_customer`/
  `_lead_apply_status`) that should refuse to run against today's live
  function — the pinned hash no longer matches after the Nov 3 fix — but
  that guard is the only thing standing between this file and a silent
  regression, so it stays parked rather than relying on the guard alone.
  The `.apply.sql.out.txt` found alongside it (`"applied":true`,
  `applied_at: 2026-11-02 13:16:58`) is leftover from an earlier run of a
  precursor version of this same dedupe/advisory-lock work, from before
  this "rebased" file and its stale pin existed — it is not evidence that
  *this* committed file was ever applied; `supabase_migrations.schema_migrations`
  has no `20261204120000` row as of this parking. Needs a full rebase onto
  the current live `create_customer_with_details` body (with `full_address`,
  not the legacy columns) before it can be reconsidered — do not just
  re-pin and re-apply as-is.
