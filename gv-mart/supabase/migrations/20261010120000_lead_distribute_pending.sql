-- Distribute waiting leads (auto_assign_pending) round robin, oldest first, when a sales
-- person becomes eligible or the switch is turned ON. Approved design 2026-10-07.
--
--   * Only leads flagged auto_assign_pending are ever touched. Leads that existed before
--     auto-assign went live are never flagged, so they are never touched.
--   * Runs only while settings.auto_assign_leads is ON, and takes the same per-organisation
--     advisory lock as the insert trigger (lead_rr:<org>).
--   * A flagged lead that was closed (won/lost) or assigned by hand meanwhile just has the
--     flag cleared; its assignee/status is left alone.
--   * Uses the same pick as new leads (least recently auto-assigned first), logs a
--     lead_assignments row + notification per lead, and marks the master's waiting notice read
--     once nothing is left waiting.
--   * Internal only: REVOKE ALL FROM PUBLIC, anon, authenticated. Called by triggers.

create or replace function public._lead_distribute_pending(p_org uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_pick uuid;
  v_n integer := 0;
begin
  if not coalesce((select s.auto_assign_leads from public.settings s where s.org_id = p_org), false) then
    return 0;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('lead_rr:' || p_org::text, 0));

  -- nothing to assign for these: just clear the flag
  update public.leads set auto_assign_pending = false
   where org_id = p_org and auto_assign_pending
     and (assigned_to is not null or status in ('won', 'lost'));

  for r in
    select l.id, l.name, l.mobile
      from public.leads l
     where l.org_id = p_org and l.auto_assign_pending and l.assigned_to is null
     order by l.created_at, l.id
       for update
  loop
    v_pick := public._lead_rr_pick(p_org);
    exit when v_pick is null;

    insert into public.lead_rotation (profile_id, org_id, last_auto_assigned_at)
    values (v_pick, p_org, clock_timestamp())
    on conflict (profile_id) do update set last_auto_assigned_at = excluded.last_auto_assigned_at;

    perform set_config('app.lead_assign_ok', '1', true);
    update public.leads set assigned_to = v_pick, auto_assign_pending = false where id = r.id;
    perform set_config('app.lead_assign_ok', '', true);

    insert into public.lead_assignments (org_id, lead_id, from_user, to_user, assigned_by, reason)
    values (p_org, r.id, null, v_pick, null, 'auto round-robin (waiting lead)');

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (p_org, v_pick, 'lead_assigned', 'A waiting lead was assigned to you',
            format('%s%s — auto-assigned', coalesce(r.name, 'Lead'), coalesce(' (' || r.mobile || ')', '')), r.id);

    v_n := v_n + 1;
  end loop;

  if not exists (select 1 from public.leads where org_id = p_org and auto_assign_pending) then
    update public.notifications set is_read = true
     where org_id = p_org and role = 'master' and type = 'lead_auto_assign_waiting' and not is_read;
  end if;

  return v_n;
end;
$$;

-- a person becomes eligible (added, activated, switched back on, or promoted to sales_admin)
create or replace function public._trg_profile_distribute_pending()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.role = 'sales_admin' and new.is_active and new.receives_new_leads
     and (tg_op = 'INSERT' or not (old.role = 'sales_admin' and old.is_active and old.receives_new_leads)) then
    perform public._lead_distribute_pending(new.org_id);
  end if;
  return null;
end;
$$;
drop trigger if exists profiles_distribute_pending on public.profiles;
create trigger profiles_distribute_pending
  after insert or update of role, is_active, receives_new_leads on public.profiles
  for each row execute function public._trg_profile_distribute_pending();

-- the switch goes OFF -> ON
create or replace function public._trg_settings_distribute_pending()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.auto_assign_leads and not old.auto_assign_leads then
    perform public._lead_distribute_pending(new.org_id);
  end if;
  return null;
end;
$$;
drop trigger if exists settings_distribute_pending on public.settings;
create trigger settings_distribute_pending
  after update of auto_assign_leads on public.settings
  for each row execute function public._trg_settings_distribute_pending();

revoke all on function public._lead_distribute_pending(uuid) from public, anon, authenticated;
revoke all on function public._trg_profile_distribute_pending() from public, anon, authenticated;
revoke all on function public._trg_settings_distribute_pending() from public, anon, authenticated;
