# DECISIONS — urgent multi-fix window (2026-11-02)

Log for the outage and the item #4/#1 migration-ordering hazard found during
this window. (Earlier hotfix commits on this date say "see DECISIONS.md" --
that was a wrong assumption; `DECISIONS.md` and `OPEN_DECISIONS.md` are both
scoped to unrelated earlier features, not a general log. This file is the
correct one for anyone following those comments.)

## 1) Outage: p_technician_id

Urgent item #1's push (`513c29d`) made `createComplaintTicket` send
`p_technician_id` on every `create_complaint_ticket` RPC call. The live
function (migration `20261202090000`, parked below) was never applied, so it
has 18 params, no `p_technician_id` -- every "New Complaint" submission
failed with a function-not-found error from the moment that commit reached
production until the frontend-only revert (`acc11e1`).

Separately found during the same check: item #5's "Technician availability"
toggle on the ticket detail page calls `get_technician_availability_for_date`
(migration `20261202100000`, also not applied) -- hidden in the same revert.
Separately found during the audit pass right after: item #3's Edit Lead
pencil icon calls `update_lead_details` (migration `20261201110000`, also
not applied) -- hidden in `1761eaa`.

**Lesson, now a standing process rule for this window:** the database object
is applied and verified live FIRST; the frontend that calls it is pushed
SECOND. Never the reverse.

## 2) Migration-ordering hazard: #4 vs #1

Item #4's migration (`20261201100100`) and item #1's migration
(`20261202090000`) both redefine `_create_complaint_ticket_internal` /
`create_complaint_ticket`. #1's migration was written against the body that
was live BEFORE #4's fix landed (copied from `20261024160000`'s definition).
Applying #4 then #1 in timestamp order -- the normal order -- would have #1's
`CREATE OR REPLACE` silently overwrite #4's fix with the old buggy retry
loop, since neither author's migration was aware of the other's change to
the same function.

**Decision:** merge both into one migration
(`20261202120000_complaint_daybump_fix_and_technician_pick_merged.sql`),
built from a fresh live pin taken immediately before writing it, containing
both fixes in one body. The two originals are moved (not deleted) to
`gv-mart/supabase/migrations/_parked/` with their own README explaining why,
so neither can be applied standalone by mistake.

**Takeaway for future parallel work on this repo:** two migrations touching
the same function, authored in different branches/worktrees without either
seeing the other's diff, is a real and recurring risk in this project's
heavily-parallel-worktree workflow. Worth a standing check before any apply:
`git log --all -- <migration path or proname>` for other unapplied
migrations touching the same function, not just the one being reviewed.
