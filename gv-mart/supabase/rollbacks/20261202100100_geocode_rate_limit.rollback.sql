-- Rollback for 20261202100100_geocode_rate_limit.sql.
-- Everything this migration created is brand new (nothing redefined, no column/type changes
-- on any pre-existing table) -- unscheduling the cron job, then dropping the two functions,
-- then dropping the table is the complete undo. Safe to run at any time: geocode_rate_limits
-- holds nothing but per-user call counters, no data anyone depends on. Order matters only in
-- that the cron job references cleanup_geocode_rate_limits() by name, not by OID, so
-- unscheduling first avoids a dangling schedule pointing at a function that no longer exists
-- in the window between these statements (cosmetic safety, not a hard requirement -- pg_cron
-- tolerates a missing target function at run time by simply failing that one run).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'geocode-rate-limit-cleanup') then
    perform cron.unschedule('geocode-rate-limit-cleanup');
  end if;
end
$$;
drop function if exists public.cleanup_geocode_rate_limits();
drop function if exists public.check_and_increment_geocode_rate_limit(uuid, integer, integer, integer, integer);
drop table if exists public.geocode_rate_limits;
delete from supabase_migrations.schema_migrations where version = '20261202100100';
