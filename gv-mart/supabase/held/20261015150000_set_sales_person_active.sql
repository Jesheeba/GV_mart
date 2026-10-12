-- HELD (design: docs/design-admin-set-staff-active.md, decisions 2026-10-12): database half of admin-set-staff-active.
--
-- set_sales_person_active(p_actor, p_profile_id, p_active): service-role only, ONE transaction.
--   * re-checks in the database that p_actor is an ACTIVE master, the target is a sales_admin of the SAME organisation,
--     the target is not the actor and not a master (the Edge Function checks too; this is the second lock);
--   * idempotent: if the person is already in the requested state it changes nothing and says so;
--   * deactivation:
--       - open leads (not won/lost) assigned to them are returned to the pool: assigned_to = NULL and
--         auto_assign_pending = true ("needs reassignment" for the next distribution), one lead_assignments row each
--         (reason 'deactivated', assigned_by = the acting master). Won/lost leads and history are untouched;
--       - open lead_followups assigned to them (post-service calls) go to the acting master;
--       - open / rolled tasks assigned to them are reassigned to the acting master (assigned_by unchanged);
--       - when settings.auto_assign_leads is ON and the distribution function exists, the flagged leads are spread over
--         the remaining eligible people immediately (an exception there is logged as a WARNING and swallowed, F-12);
--   * activation only flips the flag: nothing is handed back.
-- Test-customer flag (leads.is_test / customers.is_test, migration 20261016110000): flagged leads are never moved,
-- never get an assignment row and are not counted (as waiting or otherwise); follow-ups that belong to a flagged lead or a
-- flagged customer stay where they are. Tasks carry no customer link and are moved as before.
-- A trigger additionally refuses a CLIENT-side change of is_active on a sales_admin row, so the Edge Function (login
-- ban + session revocation + audit) is the only way. Masters, operation_admins and technicians are not affected by it.

create or replace function public.set_sales_person_active(p_actor uuid, p_profile_id uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor    record;
  v_target   record;
  v_leads    integer := 0;
  v_follow   integer := 0;
  v_tasks    integer := 0;
  v_switch   boolean;
  v_waiting  integer := 0;
begin
  if p_actor is null or p_profile_id is null or p_active is null then
    raise exception 'set_sales_person_active: actor, target and state are required';
  end if;

  select id, org_id, role, is_active into v_actor from public.profiles where id = p_actor;
  if not found or v_actor.role <> 'master' or not v_actor.is_active then
    raise exception 'set_sales_person_active: the actor is not an active master';
  end if;

  select id, org_id, role, is_active into v_target from public.profiles where id = p_profile_id for update;
  if not found or v_target.org_id <> v_actor.org_id then
    raise exception 'set_sales_person_active: staff member not found';
  end if;
  if v_target.role = 'master' or p_profile_id = p_actor then
    raise exception 'set_sales_person_active: a master cannot be changed here';
  end if;
  if v_target.role <> 'sales_admin' then
    raise exception 'set_sales_person_active: only a sales person can be changed here';
  end if;

  if v_target.is_active = p_active then
    return jsonb_build_object('changed', false, 'active', p_active, 'leads_unassigned', 0, 'followups_to_master', 0,
                              'tasks_to_master', 0, 'leads_waiting', 0);
  end if;

  update public.profiles set is_active = p_active where id = p_profile_id;

  if not p_active then
    perform set_config('app.lead_assign_ok', '1', true);
    with moved as (
      update public.leads
         set assigned_to = null, auto_assign_pending = true
       where org_id = v_target.org_id and assigned_to = p_profile_id and status not in ('won', 'lost') and not is_test
      returning id
    )
    insert into public.lead_assignments (org_id, lead_id, from_user, to_user, assigned_by, reason)
    select v_target.org_id, id, p_profile_id, null, p_actor, 'deactivated' from moved;
    get diagnostics v_leads = row_count;
    perform set_config('app.lead_assign_ok', '', true);

    update public.lead_followups
       set assigned_to = p_actor
     where org_id = v_target.org_id and assigned_to = p_profile_id and status = 'open'
       and not coalesce(public.is_test_customer(customer_id), false)
       and not exists (select 1 from public.leads fl where fl.id = lead_followups.lead_id and fl.is_test);
    get diagnostics v_follow = row_count;

    update public.tasks
       set assignee_id = p_actor
     where org_id = v_target.org_id and assignee_id = p_profile_id and status <> 'done';
    get diagnostics v_tasks = row_count;

    select s.auto_assign_leads into v_switch from public.settings s where s.org_id = v_target.org_id;
    if coalesce(v_switch, false) and to_regprocedure('public._lead_distribute_pending(uuid)') is not null then
      begin
        execute format('select public._lead_distribute_pending(%L::uuid)', v_target.org_id);
      exception when others then
        raise warning 'set_sales_person_active: distribution failed for org % (%): %', v_target.org_id, sqlstate, sqlerrm;
      end;
    end if;
    select count(*) into v_waiting from public.leads where org_id = v_target.org_id and auto_assign_pending and assigned_to is null and not is_test;
  end if;

  return jsonb_build_object('changed', true, 'active', p_active, 'leads_unassigned', v_leads, 'followups_to_master', v_follow,
                            'tasks_to_master', v_tasks, 'leads_waiting', v_waiting);
end;
$$;

revoke all on function public.set_sales_person_active(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.set_sales_person_active(uuid, uuid, boolean) to service_role;

-- the side door: no client-side flip of a sales person's active flag
create or replace function public.guard_sales_active_client()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon')
     and old.role = 'sales_admin'
     and new.is_active is distinct from old.is_active then
    raise exception 'profiles: use the staff deactivation function to change a sales person''s active status';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_sales_active_client() from public, anon, authenticated;

drop trigger if exists guard_sales_active_client on public.profiles;
create trigger guard_sales_active_client
  before update of is_active on public.profiles
  for each row execute function public.guard_sales_active_client();
