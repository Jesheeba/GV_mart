-- READ-ONLY snapshot for migration 20261113100000_close_spare_handover_technician_rls_hole.sql. Run by
-- hand, before and after the GO APPLY script. Nothing here writes anything. Safe to run at any time,
-- including before 11:00 IST.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Fingerprint of the rows this migration's correctness depends on (REAL orgs only, same formula as the
-- apply script's pre/post check). Run before and after; must be byte-identical in both runs since this
-- migration touches no existing row.
select jsonb_build_object(
    'spare_handovers', (select count(*) from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_handover_items', (select count(*) from public.spare_handover_items i join public.spare_handovers h on h.id = i.handover_id join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'technician_stock_levels', (select count(*) from public.technician_stock_levels s join public.organizations o on o.id = s.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'spare_returns', (select count(*) from public.spare_returns r join public.organizations o on o.id = r.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'notifications', (select count(*) from public.notifications n join public.organizations o on o.id = n.org_id where o.name not like '\_\_TEST\_%' escape '\'),
    'organizations', (select count(*) from public.organizations where name not like '\_\_TEST\_%' escape '\'),
    'checksum', (
      select md5(coalesce(string_agg(h.id::text || h.status, ',' order by h.id), ''))
      from public.spare_handovers h join public.organizations o on o.id = h.org_id where o.name not like '\_\_TEST\_%' escape '\'
    )
  ) as fingerprint;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261113100000'
) as already_registered;

-- Current policy set on spare_handovers / spare_handover_items that this migration changes --
-- expect the two write_own_technician FOR-ALL policies to exist and the two select_own_technician
-- policies to be absent before, and the reverse after.
select
  exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handovers'::regclass and pol.polname = 'spare_handovers_write_own_technician') as spare_handovers_write_own_technician_exists,
  exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handover_items'::regclass and pol.polname = 'spare_handover_items_write_own_technician') as spare_handover_items_write_own_technician_exists,
  exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handovers'::regclass and pol.polname = 'spare_handovers_select_own_technician') as spare_handovers_select_own_technician_exists,
  exists (select 1 from pg_policy pol where pol.polrelid = 'public.spare_handover_items'::regclass and pol.polname = 'spare_handover_items_select_own_technician') as spare_handover_items_select_own_technician_exists;

-- Current security mode of confirm_spare_handover -- expect false (invoker) before, true (definer)
-- after, and its privilege state.
select
  prosecdef as confirm_spare_handover_is_definer,
  has_function_privilege('anon', 'public.confirm_spare_handover(uuid, text, text)', 'execute') as confirm_spare_handover_anon,
  has_function_privilege('authenticated', 'public.confirm_spare_handover(uuid, text, text)', 'execute') as confirm_spare_handover_authenticated
from pg_proc where oid = 'public.confirm_spare_handover(uuid,text,text)'::regprocedure;
