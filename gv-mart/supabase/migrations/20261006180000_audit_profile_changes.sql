-- Audit trail for the columns that grant power: profiles.role / org_id /
-- staff_role_key / is_active. Until now profile changes were never audited,
-- so the 2026-10-05 privilege-escalation hole could not have been detected
-- after the fact.
--
-- One audit_log row per profile INSERT, DELETE, or UPDATE that actually
-- changes one of those four columns. actor_id = auth.uid() (the signed-in
-- user who made the change; null when the service role / a cron / a
-- migration did it). `db_role` records which Postgres role executed the
-- write (authenticated = a client write, postgres/service_role = server-side).
-- SECURITY DEFINER because audit_log has no client INSERT policy.

create or replace function public.audit_profile_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

  -- audit_log.actor_id is an FK to profiles: only set it if that profile exists
  -- (a service-role write has no auth.uid(); a deleted profile can't be cited)
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
$$;

drop trigger if exists audit_profile_changes on public.profiles;
create trigger audit_profile_changes
  after insert or delete or update on public.profiles
  for each row execute function public.audit_profile_changes();
