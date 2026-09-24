-- Expense/Accounts tracking (money-out) — see 20260924120000 for the
-- change-request authorization note against the v2.2 scope guard.
--
-- `note` — free text (payee/vendor name, e.g. "TNEB", "Landlord", a
-- technician's name for a manual salary payout). No separate payee/vendor
-- master table — that would edge into "vendor price-history" territory,
-- also on the do-NOT-build list. Plain text is enough for a ledger note.
--
-- `recurring_task_id` — optional link back to the recurring task (EB bill,
-- salary processing) that this expense was logged against, so a reminder
-- can be turned into a real ledger entry. Nullable/optional by design: an
-- unplanned expense (emergency repair, surprise purchase) is logged exactly
-- the same way as a routine one, with no task link at all.
--
-- `is_recurring` — denormalized flag mirroring whether this entry came from
-- a recurring task, for cheap filtering/reporting without a join.
--
-- `logged_by` — audit trail of who recorded the spend. RLS is unchanged:
-- expenses_write_ops (20260701091300_rls.sql) already lets ops staff write;
-- expenses_select_master already restricts reads to master.

alter table public.expenses add column if not exists note text;
alter table public.expenses add column if not exists is_recurring boolean not null default false;
alter table public.expenses add column if not exists recurring_task_id uuid references public.tasks (id) on delete set null;
alter table public.expenses add column if not exists logged_by uuid references public.profiles (id) on delete set null;

create index if not exists expenses_recurring_task_id_idx on public.expenses (recurring_task_id) where recurring_task_id is not null;
create index if not exists expenses_date_idx on public.expenses (org_id, date);
