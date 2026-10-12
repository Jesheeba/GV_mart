# Items 1 (AMC) and 5 (test-customer flag) — live apply steps (NOT run; waiting for approval)

Branch `feat/b17-amc-fix-test-flag` (worktree GV_mart_b17_amcflag). Nothing here has been applied to the live database.

## Order
1. Backups — already taken: `Desktop\GV_mart_db_backup_2026-10-15_items_1_5` (functions, index, AMC rows).
2. Apply `20261015100000_amc_cancel_visit_scheduling_overlap.sql` (Management API + migration-history row).
   Pre-check: no technician holds two overlapping open appointments (the new constraint would refuse). Rolled-back run on live: OK.
3. Apply `20261015110000_test_customer_flag.sql` (+ history row).
4. Verify on live (read-only): function hashes vs the migration, constraint present, `select count(*)` of flagged = 0.
5. Cancel the 8 Oct AMC contract: `cancel_amc_contract('711677e3-…', 'Test contract from 8 Oct referral test')` as master
   (or one SQL statement through the same code path under the master's profile). Verify: 6 tickets cancelled, both technicians
   have no open appointment, `get_technician_current_job` empty.
6. Create customer "jeshee test trigger" (Sirah Digital, Pallavaram, test mobile) with `is_test = true`; verify the existing lead
   with the same number became `is_test = true`; verify it is absent from customers count, lead funnel, follow-up lists, reports.
7. Push (fast-forward origin/main only) → Vercel → verify bundle strings ("Test" badge).

## Rollback
`supabase/rollbacks/20261015110000_test_customer_flag.rollback.sql`, then `…20261015100000_amc_…rollback.sql`
(restoring the unique index fails by design if a technician already holds two open appointments).

## Behaviour changes to know about
* A technician is no longer "busy" because of a visit on another day — only an overlapping time blocks them. The
  technician app's "current job" picks the earliest open appointment; with several open jobs per technician this is the next
  one by time (unchanged code path, now reachable).
* AMC visits start at the master's working-hours start (today 09:00 → follows Masters), Sundays roll to the next working day.
* SLA for assigned visits counts from the visit time. Existing already-assigned tickets keep their stored `sla_due_at`.
