# Items 1 (AMC) and 5 (test-customer flag) — live apply steps (NOT run; waiting for approval)

Branch `feat/b17-amc-fix-test-flag` (worktree GV_mart_b17_amcflag). Nothing here has been applied to the live database.

## Versions (renamed 2026-10-15; 20261015100000-130000 belong to the security session)
* `20261016100000_amc_cancel_visit_scheduling_overlap` (AMC)
* `20261016110000_test_customer_flag` (flag)
* Later migrations continue from `20261016120000`; check `schema_migrations` and origin/main before choosing.

## Order (starts only after "cleanup is done")
1. Backups: taken (`Desktop\GV_mart_db_backup_2026-10-15_items_1_5`: functions, index, AMC rows, `acl_before.json`).
2. Re-check: drift hash of the 35 live function bodies vs the backup, ACL snapshot, `schema_migrations` versions,
   new real-organisation baseline; take the two lead hashes (count + md5) before.
3. Apply `20261016100000_amc_cancel_visit_scheduling_overlap.sql` (Management API + hand-registered history row).
   Lead hashes after. A rolled-back run on live passed 45/45; ACL compared: nothing widened.
4. Apply `20261016110000_test_customer_flag.sql` (+ history row). Lead hashes after; ACL compared again.
5. ~~Cancel the 8 Oct AMC contract~~ **Deleted by the cleanup session** (contract, tickets, appointments). Not part of this change.
6. Create customer "jeshee test trigger" (Sirah Digital, Pallavaram, test mobile) with `is_test = true`; report which lead
   shares the number and that it became `is_test = true`; lead hashes after (no real lead's `updated_at` may move).
   Verify it is absent from customers count, lead funnel, follow-up lists, reports and KPIs. WhatsApp tests only: no invoices,
   tickets or AMC for it until that is verified. Supplier "PVM" is not touched.
7. `git fetch`; rebase if origin moved; tsc and tests green; ask for push authorisation; push fast-forward; verify the Vercel
   Production deployment and the "Test" badge string in the bundle.

## Rollback
`supabase/rollbacks/20261016110000_test_customer_flag.rollback.sql`, then `…20261016100000_amc_…rollback.sql`
(restoring the unique index fails by design if a technician already holds two open appointments).

## Behaviour changes to know about
* A technician is no longer "busy" because of a visit on another day — only an overlapping time blocks them. The
  technician app's "current job" picks the earliest open appointment; with several open jobs per technician this is the next
  one by time (unchanged code path, now reachable).
* AMC visits start at the master's working-hours start (today 09:00 → follows Masters), Sundays roll to the next working day.
* SLA for assigned visits counts from the visit time. Existing already-assigned tickets keep their stored `sla_due_at`.
