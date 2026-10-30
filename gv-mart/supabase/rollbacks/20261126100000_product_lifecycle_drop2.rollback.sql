-- ROLLBACK script for Product Lifecycle Drop 2 (migrations 20261126100000-20261126100200).
-- WRITTEN ONLY -- never executed against the LIVE database by the agent that produced this
-- file until explicitly asked to run it there; it WAS exercised end-to-end against a local
-- pglite instance (apply -> verify -> rollback -> verify original state restored).
--
-- Drops every object Drop 2 created. Unlike Drop 1's rollback, nothing here replaces a
-- pre-existing live function -- all 6 functions and the 1 table are entirely new, so this is
-- pure removal, no "restore the original text" step needed.

do $rollback$
declare
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
begin
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o where o.name not like '%__TEST_%' order by o.created_at asc limit 1;
  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'ROLLBACK ORG CHECK: fingerprint mismatch (expected %, got %) -- refusing', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  set lock_timeout = '5s';

  drop function if exists public.get_lifecycle_followups_for_sales(uuid);
  drop function if exists public.get_customer_replacement_history(uuid);
  drop function if exists public.get_customer_installed_products(uuid);
  drop function if exists public.lifecycle_create_service_request(uuid);
  drop function if exists public.lifecycle_snooze_followup(uuid, date);
  drop function if exists public.lifecycle_mark_followup_contacted(uuid, text);

  drop table if exists public.lifecycle_followup_actions cascade;

  alter table public.customer_part_schedules drop column if exists snoozed_until;

  delete from supabase_migrations.schema_migrations
  where version in ('20261126100000', '20261126100100', '20261126100200');

  raise notice 'ROLLBACK OK: Drop 2 objects removed, org fingerprint unchanged (%)', v_org_fingerprint;
end;
$rollback$;
