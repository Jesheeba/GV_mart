-- REHEARSAL of 20261024100000_close_public_and_anon_function_execute: ONE request, never commits.
-- Layout: (1) before-state capture, (2) the migration's own DO block, verbatim, (3) an after-state block that raises.
-- Expected outcome: the request FAILS with an error whose text starts REHEARSAL_OK followed by counts.
-- Any other error text means one of the migration's own assertions (or a statement) failed. Either way the whole
-- transaction is rolled back and nothing is changed.
create temp table rehearsal_acl_before as
select p.oid::regprocedure::text as sig, coalesce(p.proacl::text, 'NULL') as acl
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p');

create temp table rehearsal_counts_before as
select
  (select count(*) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
      and (p.proacl is null
           or exists (select 1 from aclexplode(p.proacl) a
                       where a.privilege_type = 'EXECUTE'
                         and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))))) as open_before,
  (select count(*) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prorettype = 'trigger'::regtype
      and has_function_privilege('authenticated', p.oid, 'execute')) as trigger_auth_before,
  (select count(*) from pg_default_acl
    where defaclrole = 'postgres'::regrole and defaclnamespace = 0 and defaclobjtype = 'f') as global_default_rows_before;

do $mig$
declare
  v_trigger_group text[] := array[
    '_attendance_compute_status',
    '_auto_draft_purchase_order',
    '_gift_create_inventory_row',
    '_gift_log_decrement_stock',
    '_milestone_invoice_notify',
    '_milestone_ticket_notify',
    '_milestone_visit_notify',
    '_notify_customer_ticket_milestone',
    '_notify_customer_visit_started',
    '_notify_task_assigned',
    '_notify_technician_low_stock',
    '_on_attendance_present_assign_backlog',
    '_po_task_completed_marks_paid',
    '_service_tickets_derive_skill_and_duration',
    '_technicians_deactivate_clears_duty',
    'audit_master_change',
    'audit_profile_changes',
    'enforce_customer_members_limit',
    'guard_appointment_technician_update',
    'guard_customer_self_update',
    'guard_notification_recipient_update',
    'guard_profile_privileged_columns',
    'guard_profile_staff_role_key',
    'guard_technician_tier_change',
    'set_updated_at',
    'stamp_technician_tier_changed_at'
  ];
  r record;
  v_touched int := 0;
begin
  -- A rebuild from migrations must never leave the retired linking function open.
  if to_regprocedure('public.link_customer_google_account(text)') is not null then
    revoke execute on function public.link_customer_google_account(text) from public, anon, authenticated;
  end if;

  for r in
    select p.oid::regprocedure::text as sig,
           p.proname as name,
           (p.prorettype = 'trigger'::regtype) as is_trigger,
           (p.proacl is null
              or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as has_public,
           coalesce((select true from aclexplode(p.proacl) a
                      where a.grantee = (select oid from pg_roles where rolname = 'authenticated')
                        and a.privilege_type = 'EXECUTE' limit 1), false) as has_authenticated
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proowner = 'postgres'::regrole
      and p.prokind in ('f', 'p')
      and (p.proacl is null
           or exists (select 1 from aclexplode(p.proacl) a
                       where a.privilege_type = 'EXECUTE'
                         and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))))
    order by 1
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);

    if r.is_trigger or r.name = any (v_trigger_group) then
      execute format('revoke execute on function %s from authenticated', r.sig);
    elsif r.has_public or r.has_authenticated then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;

    v_touched := v_touched + 1;
  end loop;

  raise notice 'close_public_and_anon_function_execute: % functions updated', v_touched;

  -- Closed by default from now on.
  alter default privileges for role postgres revoke execute on functions from public;

  -- Assertions: the migration fails (and rolls back as a whole) unless the end state is exactly as intended.
  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
      and (p.proacl is null
           or exists (select 1 from aclexplode(p.proacl) a
                       where a.privilege_type = 'EXECUTE'
                         and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))))
  ) then
    raise exception 'assertion failed: a public function still has PUBLIC or anon EXECUTE';
  end if;

  if exists (
    select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole
      and (p.prorettype = 'trigger'::regtype or p.proname = any (v_trigger_group))
      and has_function_privilege('authenticated', p.oid, 'execute')
  ) then
    raise exception 'assertion failed: a trigger function is still executable by authenticated';
  end if;

  if has_function_privilege('anon', 'public.create_sale(uuid,uuid,jsonb,uuid,integer,uuid,numeric)', 'execute')
     or has_function_privilege('anon', 'public.is_master()', 'execute')
     or has_function_privilege('anon', 'public.current_org_id()', 'execute') then
    raise exception 'assertion failed: anon can still execute a guarded function';
  end if;

  if not (has_function_privilege('authenticated', 'public.create_sale(uuid,uuid,jsonb,uuid,integer,uuid,numeric)', 'execute')
          and has_function_privilege('authenticated', 'public.is_master()', 'execute')
          and has_function_privilege('authenticated', 'public.current_org_id()', 'execute')
          and has_function_privilege('authenticated', 'public.renew_amc_plan(uuid,uuid,uuid,text,integer,text,uuid)', 'execute')
          and has_function_privilege('service_role', 'public.create_sale(uuid,uuid,jsonb,uuid,integer,uuid,numeric)', 'execute')) then
    raise exception 'assertion failed: authenticated or service_role lost access to an application function';
  end if;

  if exists (
    select 1 from pg_default_acl d
    where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 0 and d.defaclobjtype = 'f'
      and exists (select 1 from aclexplode(d.defaclacl) a where a.grantee = 0)
  ) or not exists (
    select 1 from pg_default_acl d
    where d.defaclrole = 'postgres'::regrole and d.defaclnamespace = 0 and d.defaclobjtype = 'f'
  ) then
    raise exception 'assertion failed: the global function default privilege is not closed';
  end if;
end
$mig$;

do $rehearsal$
declare
  b record;
  v_total int; v_open_after int; v_trigger_auth_after int; v_callable_auth int; v_service int; v_global_rows int; v_changed int;
begin
  select * into b from rehearsal_counts_before;
  select count(*) into v_total from rehearsal_acl_before;

  select count(*) into v_open_after from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
     and (p.proacl is null
          or exists (select 1 from aclexplode(p.proacl) a
                      where a.privilege_type = 'EXECUTE'
                        and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))));
  select count(*) into v_trigger_auth_after from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prorettype = 'trigger'::regtype
     and has_function_privilege('authenticated', p.oid, 'execute');
  select count(*) into v_callable_auth from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
     and p.prorettype <> 'trigger'::regtype and has_function_privilege('authenticated', p.oid, 'execute');
  select count(*) into v_service from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
     and has_function_privilege('service_role', p.oid, 'execute');
  select count(*) into v_global_rows from pg_default_acl
   where defaclrole = 'postgres'::regrole and defaclnamespace = 0 and defaclobjtype = 'f';
  select count(*) into v_changed
    from pg_proc p join rehearsal_acl_before r on r.sig = p.oid::regprocedure::text
   where coalesce(p.proacl::text, 'NULL') <> r.acl;

  if v_open_after <> 0 then
    raise exception 'REHEARSAL_FAILED open functions remain: %', v_open_after;
  end if;
  if v_trigger_auth_after <> 0 then
    raise exception 'REHEARSAL_FAILED trigger functions still executable by authenticated: %', v_trigger_auth_after;
  end if;
  if v_changed <> b.open_before then
    raise exception 'REHEARSAL_FAILED changed % functions but % were open', v_changed, b.open_before;
  end if;

  raise exception 'REHEARSAL_OK %', jsonb_build_object(
    'functions_total', v_total,
    'open_before', b.open_before, 'open_after', v_open_after,
    'functions_whose_acl_changed', v_changed,
    'trigger_functions_executable_by_authenticated', jsonb_build_object('before', b.trigger_auth_before, 'after', v_trigger_auth_after),
    'non_trigger_functions_executable_by_authenticated_after', v_callable_auth,
    'functions_executable_by_service_role_after', v_service,
    'global_default_rows', jsonb_build_object('before', b.global_default_rows_before, 'after', v_global_rows))::text;
end
$rehearsal$;
