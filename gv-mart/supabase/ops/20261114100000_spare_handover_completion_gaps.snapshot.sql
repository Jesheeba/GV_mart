-- READ-ONLY snapshot for migration 20261114100000_spare_handover_completion_gaps.sql. Run by hand,
-- before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/to_regclass so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Prerequisite: 20261113100000 must already be registered, and confirm_spare_handover must already be
-- SECURITY DEFINER (proves it actually took effect, not just that the version row exists).
select
  exists(select 1 from supabase_migrations.schema_migrations where version = '20261113100000') as prereq_registered,
  (select prosecdef from pg_proc where oid = 'public.confirm_spare_handover(uuid,text,text)'::regprocedure) as confirm_spare_handover_is_definer;

-- Fingerprint of the rows this migration's correctness depends on (REAL orgs only, same formula as the
-- apply script's pre/post check). Run before and after; must be byte-identical in both runs since this
-- migration touches no existing row.
select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'inventory_movements', (select count(*) from public.inventory_movements m join public.organizations o on o.id = m.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || coalesce(h.technician_id::text, '') || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) as fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261114100000'
) as already_registered;

-- Whether each new object already exists (expect false/NULL before, true/not-null after).
select
  to_regprocedure('public.report_spare_handover_discrepancy(uuid,uuid,integer,text)') is not null as report_spare_handover_discrepancy_exists,
  to_regclass('public.technician_spare_ledger') is not null as technician_spare_ledger_exists;

-- Whether the 3 new columns already exist (expect false before, true after).
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'spare_handovers' and column_name = 'given_by') as spare_handovers_given_by_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'spare_handover_items' and column_name = 'received_qty') as spare_handover_items_received_qty_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'spare_handover_items' and column_name = 'dispute_note') as spare_handover_items_dispute_note_exists;

-- Privilege state, guarded against each object being absent.
select
  case when to_regprocedure('public.report_spare_handover_discrepancy(uuid,uuid,integer,text)') is null then null
       else has_function_privilege('anon', 'public.report_spare_handover_discrepancy(uuid, uuid, integer, text)', 'execute') end as report_spare_handover_discrepancy_anon,
  case when to_regprocedure('public.report_spare_handover_discrepancy(uuid,uuid,integer,text)') is null then null
       else has_function_privilege('authenticated', 'public.report_spare_handover_discrepancy(uuid, uuid, integer, text)', 'execute') end as report_spare_handover_discrepancy_authenticated,
  case when to_regclass('public.technician_spare_ledger') is null then null
       else has_table_privilege('anon', 'public.technician_spare_ledger', 'SELECT') end as technician_spare_ledger_anon,
  case when to_regclass('public.technician_spare_ledger') is null then null
       else has_table_privilege('authenticated', 'public.technician_spare_ledger', 'SELECT') end as technician_spare_ledger_authenticated;
