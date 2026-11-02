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
