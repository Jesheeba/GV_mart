-- 20261024100000_close_public_and_anon_function_execute.sql
--
-- Closes EXECUTE for PUBLIC and anon on every postgres-owned function in schema public, and
-- makes the closure the default for functions created from now on.
--
-- Why: a new function created by postgres in public is born with PUBLIC EXECUTE (probe, 2026-10-14:
-- proacl {=X/postgres,postgres=X/postgres,service_role=X/postgres}); the earlier per-schema
-- "revoke ... from public" never removed it. anon reaches such a function through PUBLIC.
--
-- Evidence this is safe (read-only audit 2026-10-14): anon holds no table privilege in public;
-- the only unauthenticated route is /login and it makes no RPC; no Edge Function uses an anon key;
-- no auth hook is enabled; the three anon storage policies call no function; every open function is
-- either an app RPC (authenticated), an RLS/constraint helper (authenticated, evaluated as the
-- caller) or a trigger function (no EXECUTE check at fire time).
--
-- Rule applied to each function that has PUBLIC or anon EXECUTE:
--   * revoke from PUBLIC and anon;
--   * grant to service_role (Edge Functions, cron);
--   * trigger-returning functions (and the named trigger group): also revoke authenticated;
--   * every other function: keep authenticated access, made explicit (it was held via PUBLIC or a direct grant).
-- Functions created by earlier migrations in the same chain (for example the AMC helpers in
-- 20261022100000) are covered by the same loop; they keep authenticated access only if they had it.
--
-- Caveat recorded for review: the final statement is the GLOBAL default (no IN SCHEMA), so it also
-- applies to functions that postgres creates in other schemas later (for example `create extension`).
-- Such functions will need an explicit grant where authenticated/anon callers must use them.
--
-- Exact rollback: supabase/rollbacks/20261024100000_close_public_and_anon_function_execute.rollback.sql, driven by the ACL snapshot
-- supabase/rollbacks/20261024100000_close_public_and_anon_function_execute.acl_snapshot.json taken before this migration.

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
