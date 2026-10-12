-- Rollback for held/20261011110000_audit_log_append_only.sql: restores the previous (mutable) state.
-- Previous ACL on audit_log: Supabase default grants (anon/authenticated/service_role had ALL, RLS gated clients).
drop trigger if exists audit_log_append_only on public.audit_log;
drop trigger if exists audit_log_no_truncate on public.audit_log;
drop function if exists public._trg_audit_log_append_only();
drop function if exists public.purge_test_organisation(uuid);
grant update, delete, truncate on public.audit_log to anon, authenticated, service_role;
-- restore the two audit trigger functions exactly as they were live before this migration
create or replace function public.audit_master_change()
 returns trigger language plpgsql security definer set search_path to 'public'
as \$
declare
  v_org_id uuid;
  v_row_id uuid;
begin
  if TG_OP = 'DELETE' then
    v_org_id := old.org_id;
    v_row_id := old.id;
  else
    v_org_id := new.org_id;
    v_row_id := new.id;
  end if;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_org_id,
    auth.uid(),
    TG_OP,
    TG_TABLE_NAME,
    v_row_id,
    case when TG_OP in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when TG_OP in ('INSERT', 'UPDATE') then to_jsonb(new) else null end
  );

  if TG_OP = 'DELETE' then
    return old;
  end if;
  return new;
end;
\$;

create or replace function public.audit_profile_changes()
 returns trigger language plpgsql security definer set search_path to 'public'
as \$
declare
  v_actor uuid;
  v_before jsonb;
  v_after jsonb;
begin
  if tg_op = 'UPDATE'
     and new.role is not distinct from old.role
     and new.org_id is not distinct from old.org_id
     and new.staff_role_key is not distinct from old.staff_role_key
     and new.is_active is not distinct from old.is_active then
    return new;
  end if;

  select id into v_actor from public.profiles where id = auth.uid();

  if tg_op in ('UPDATE', 'DELETE') then
    v_before := jsonb_build_object(
      'full_name', old.full_name, 'role', old.role, 'org_id', old.org_id,
      'staff_role_key', old.staff_role_key, 'is_active', old.is_active,
      'db_role', current_user);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_after := jsonb_build_object(
      'full_name', new.full_name, 'role', new.role, 'org_id', new.org_id,
      'staff_role_key', new.staff_role_key, 'is_active', new.is_active,
      'db_role', current_user);
  end if;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    coalesce(case when tg_op = 'DELETE' then old.org_id else new.org_id end, old.org_id),
    v_actor,
    tg_op,
    'profiles',
    case when tg_op = 'DELETE' then old.id else new.id end,
    v_before,
    v_after
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
\$;
