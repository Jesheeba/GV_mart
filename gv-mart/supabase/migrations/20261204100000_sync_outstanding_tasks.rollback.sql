-- ROLLBACK script for 20261204100000_sync_outstanding_tasks.sql
-- Drops everything the migration added, in reverse order. Exercised proof
-- that this runs clean with zero residue lives in the sibling
-- *.rollback_exercise.apply.dryrun.sql file (applies the migration, runs
-- this exact DDL, verifies catalog state returns to pre-migration, then
-- force-rolls-back the whole probe -- nothing in that proof run is ever
-- committed).

do $$
begin
  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    perform cron.unschedule('sync-outstanding-tasks');
  end if;
end
$$;

drop function if exists public.refresh_outstanding_tasks();
drop function if exists public.sync_outstanding_tasks();
drop function if exists public._sync_outstanding_tasks_for_org(uuid);

drop index if exists public.tasks_customer_outstanding_one_open_idx;

alter table public.settings drop column if exists min_outstanding_balance;
alter table public.settings drop column if exists min_outstanding_days;
alter table public.settings drop column if exists default_accounts_owner_id;

delete from supabase_migrations.schema_migrations where version = '20261204100000';
