-- AMC visit release path: an assigned future AMC visit is taken back when its technician becomes unavailable.
--
-- PROBLEM (owner decision 2026-10-14, "blocker introduced by assignment-at-sale"): migration 20261022100000 assigns AMC visits
-- that fall inside settings.amc_assign_window_days at sale and, later, from the daily job. The daily job only looks at
-- UNASSIGNED visits, so a visit already assigned to a technician who is then deactivated, or who goes on leave on that day,
-- stayed on that person until someone noticed. Same pattern as the cancelled contract's six appointments and Gap C:
-- work is given to a person and nothing takes it back.
--
-- WHAT THIS MIGRATION DOES
--   1. _amc_visit_unavailable_reason(technician, date) is the one definition of "cannot do a visit on that date":
--        'inactive' - technicians.is_active = false (the assignment engine hard-excludes these)
--        'leave'    - a technician_availability row for that date with status = 'leave' (the engine's own leave test)
--      Capacity is deliberately NOT a reason: a technician over capacity may have been given the visit by a person on purpose,
--      and nothing marks an assignment as manual or automatic, so releasing it would override a human decision.
--   2. release_unavailable_amc_visits(p_now, p_technician_id, p_date) finds future AMC contract visits that are assigned
--      (ticket status 'assigned', appointment 'scheduled', dated at or after p_now, no in-progress appointment on the ticket)
--      to a technician for whom (1) gives a reason, and for each one, in its own sub-transaction:
--        - clears the appointment's technician,
--        - writes a "visit withdrawn" notification to that technician (a notice, not only a read mark),
--        - writes an audit_log row (action 'amc_visit_released', actor null: it is a system action) naming the reason,
--        - inside the assignment window: runs the SAME engine (_auto_assign_ticket_internal) at once. The ticket status is
--          not flipped first, so a successful hand-over fires no new customer milestone. If nobody is free the ticket goes
--          back to open (assigned_at and sla_due_at cleared) and the engine's usual "needs manual assignment" alert is raised
--          once for it.
--        - beyond the window: the ticket goes back to open and the daily assign_due_amc_visits() picks it up when due.
--      A failure in one visit never stops the others and leaves that visit untouched (it is retried on the next run).
--      Idempotent: a released visit has no technician and is not selected again. Returns counts.
--   3. amc_assign_cron_tick() runs release_unavailable_amc_visits() BEFORE assign_due_amc_visits() in the same daily run, and
--      records an 'error' heartbeat if any visit failed to release (the existing dead-man check then alerts the master).
--   4. Two triggers run the same release immediately, scoped to the one technician (and date), so a visit dated today is not
--      left on someone until the next morning:
--        technicians: is_active true -> false
--        technician_availability: a row becomes status 'leave' (insert or update of status / date)
--      Both swallow any error: they must never block the deactivation or the leave entry itself.
-- Nothing is deleted. Visits in progress, completed, cancelled, already past, or not belonging to a contract are never touched.

-- ── the one definition of "unavailable on that date" ─────────────────────────────────────────────────────────────────────
create or replace function public._amc_visit_unavailable_reason(p_technician_id uuid, p_date date)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
           when not t.is_active then 'inactive'
           when exists (select 1 from public.technician_availability ta
                         where ta.technician_id = t.id and ta.date = p_date and ta.status = 'leave') then 'leave'
         end
    from public.technicians t
   where t.id = p_technician_id
$$;
revoke all on function public._amc_visit_unavailable_reason(uuid, date) from public, anon, authenticated;
grant execute on function public._amc_visit_unavailable_reason(uuid, date) to service_role;

-- ── the release ──────────────────────────────────────────────────────────────────────────────────────────────────────────
create or replace function public.release_unavailable_amc_visits(
  p_now           timestamptz default now(),
  p_technician_id uuid        default null,
  p_date          date        default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r             record;
  v_today       date := (p_now at time zone 'Asia/Kolkata')::date;
  v_window      integer;
  v_reason      text;
  v_res         jsonb;
  v_n           integer;
  v_outcome     text;
  v_profile     uuid;
  v_considered  integer := 0;
  v_released    integer := 0;
  v_reassigned  integer := 0;
  v_unassigned  integer := 0;
  v_errors      integer := 0;
begin
  for r in
    select a.id            as appointment_id,
           a.ticket_id,
           t.org_id,
           a.technician_id,
           a.scheduled_at,
           (a.scheduled_at at time zone 'Asia/Kolkata')::date as visit_date
      from public.appointments a
      join public.service_tickets t on t.id = a.ticket_id
     where t.contract_id is not null
       and t.type = 'amc'
       and t.status = 'assigned'
       and a.status = 'scheduled'
       and a.technician_id is not null
       and a.scheduled_at is not null
       and a.scheduled_at >= p_now
       and (p_technician_id is null or a.technician_id = p_technician_id)
       and (p_date is null or (a.scheduled_at at time zone 'Asia/Kolkata')::date = p_date)
       and not exists (select 1 from public.appointments x where x.ticket_id = t.id and x.status = 'in_progress')
       and public._amc_visit_unavailable_reason(a.technician_id, (a.scheduled_at at time zone 'Asia/Kolkata')::date) is not null
     order by a.scheduled_at, a.id
       for update of a skip locked
  loop
    v_considered := v_considered + 1;
    begin
      v_reason := public._amc_visit_unavailable_reason(r.technician_id, r.visit_date);
      if v_reason is null then
        continue;
      end if;

      -- take it back; the condition re-states what was selected so a concurrent change makes this a no-op
      update public.appointments
         set technician_id = null
       where id = r.appointment_id and technician_id = r.technician_id and status = 'scheduled';
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        continue;
      end if;

      -- tell the technician: a withdrawal notice, not just a read mark on the old assignment
      select te.profile_id into v_profile from public.technicians te where te.id = r.technician_id;
      if v_profile is not null then
        insert into public.notifications (org_id, user_id, type, title, body, ref_id)
        values (r.org_id, v_profile, 'amc_visit_withdrawn', 'AMC visit withdrawn',
                format('The AMC visit on %s is no longer assigned to you (%s).', to_char(r.visit_date, 'DD Mon YYYY'),
                       case v_reason when 'inactive' then 'your account is no longer active' else 'you are on leave that day' end),
                r.appointment_id);
      end if;

      -- the honest record: a system action, not a person
      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
      values (r.org_id, null, 'amc_visit_released', 'appointments', r.appointment_id,
              jsonb_build_object('technician_id', r.technician_id, 'ticket_id', r.ticket_id, 'scheduled_at', r.scheduled_at),
              jsonb_build_object('reason', v_reason, 'released_by', 'release_unavailable_amc_visits', 'at', p_now));

      select s.amc_assign_window_days into v_window from public.settings s where s.org_id = r.org_id;
      v_window := coalesce(v_window, 7);

      if r.visit_date <= v_today + v_window then
        -- inside the window: hand it to the engine now. The ticket stays 'assigned' during the call, so a successful
        -- hand-over is not a status change and sends the customer nothing new.
        v_res := public._auto_assign_ticket_internal(r.ticket_id, r.org_id, p_skip_rating_logic => true);
        if coalesce((v_res ->> 'assigned')::boolean, false) then
          v_outcome := 'reassigned';
        else
          v_outcome := 'unassigned';
          update public.service_tickets
             set status = 'open', assigned_at = null, sla_due_at = null
           where id = r.ticket_id and status = 'assigned';
          -- the engine raises a "needs manual assignment" alert on every attempt; keep only the oldest unread one per ticket
          delete from public.notifications n
           where n.id in (
                   select x.id from public.notifications x
                    where x.type = 'ticket_unassigned' and x.ref_id = r.ticket_id and x.is_read = false
                    order by x.created_at, x.id
                   offset 1);
        end if;
      else
        -- beyond the window: back to open; assign_due_amc_visits() assigns it when it falls due
        update public.service_tickets
           set status = 'open', assigned_at = null, sla_due_at = null
         where id = r.ticket_id and status = 'assigned';
        v_outcome := 'unassigned';
      end if;

      -- counted only once the whole visit succeeded (a failed visit is rolled back and counted as an error)
      v_released := v_released + 1;
      if v_outcome = 'reassigned' then
        v_reassigned := v_reassigned + 1;
      else
        v_unassigned := v_unassigned + 1;
      end if;
    exception when others then
      -- this visit is left exactly as it was (the sub-transaction rolled back) and is retried on the next run
      v_errors := v_errors + 1;
    end;
  end loop;

  return jsonb_build_object('considered', v_considered, 'released', v_released, 'reassigned', v_reassigned,
                            'still_unassigned', v_unassigned, 'errors', v_errors);
end;
$$;
revoke all on function public.release_unavailable_amc_visits(timestamptz, uuid, date) from public, anon, authenticated;
grant execute on function public.release_unavailable_amc_visits(timestamptz, uuid, date) to service_role;

-- ── the daily run: release first, then assign what is due ─────────────────────────────────────────────────────────────────
create or replace function public.amc_assign_cron_tick(p_job_key text default 'amc_assign_due_visits')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rel jsonb;
begin
  begin
    v_rel := public.release_unavailable_amc_visits();
    perform public.assign_due_amc_visits();
  exception when others then
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;
  if coalesce((v_rel ->> 'errors')::integer, 0) > 0 then
    -- some visits could not be taken back from an unavailable technician: the dead-man check alerts the master
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', format('release path: %s visit(s) could not be released', v_rel ->> 'errors'))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end if;
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;
revoke all on function public.amc_assign_cron_tick(text) from public, anon, authenticated;
grant execute on function public.amc_assign_cron_tick(text) to service_role;

-- ── immediate triggers, scoped to the one technician (and date) ──────────────────────────────────────────────────────────
create or replace function public._trg_amc_release_on_technician_inactive()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.release_unavailable_amc_visits(now(), new.id, null);
  exception when others then
    null;   -- never block the deactivation; the daily run retries
  end;
  return null;
end;
$$;
revoke all on function public._trg_amc_release_on_technician_inactive() from public, anon, authenticated;

drop trigger if exists zz_amc_release_on_inactive on public.technicians;
create trigger zz_amc_release_on_inactive
  after update of is_active on public.technicians
  for each row when (old.is_active is true and new.is_active is not true)
  execute function public._trg_amc_release_on_technician_inactive();

create or replace function public._trg_amc_release_on_leave()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.release_unavailable_amc_visits(now(), new.technician_id, new.date);
  exception when others then
    null;   -- never block the leave entry; the daily run retries
  end;
  return null;
end;
$$;
revoke all on function public._trg_amc_release_on_leave() from public, anon, authenticated;

drop trigger if exists zz_amc_release_on_leave on public.technician_availability;
create trigger zz_amc_release_on_leave
  after insert or update of status, date on public.technician_availability
  for each row when (new.status = 'leave')
  execute function public._trg_amc_release_on_leave();

notify pgrst, 'reload schema';
