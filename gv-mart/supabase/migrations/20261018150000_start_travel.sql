-- Automation Phase 3 / Stage B, part 3: "Start travel" - the departure signal technician.on_the_way has been missing.
--
--   appointments.travel_started_at           stamped once, by the assigned technician, while the job is assigned
--   settings.automation_default_travel_eta_minutes   the estimate passed to the message (master-editable, default 30)
--   start_travel(ticket)                     the one door; emits technician.on_the_way through automation_emit
--
-- The emit is failure-isolated: if the automation engine raises, the travel stamp still commits and the error goes to
-- automation_errors. Nothing here sends anything; with no live rule and an unscheduled hand-off, a stamp produces at most a
-- dry-run queue row.

alter table public.appointments add column travel_started_at timestamptz;
alter table public.settings
  add column automation_default_travel_eta_minutes integer not null default 30 check (automation_default_travel_eta_minutes between 1 and 240);

create function public.start_travel(p_ticket_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech   uuid := public.current_technician_id();
  a        public.appointments%rowtype;
  t        public.service_tickets%rowtype;
  v_eta    integer;
  v_now    timestamptz := now();
begin
  if auth.uid() is null or v_tech is null then
    raise exception 'start_travel: only a technician can start travel';
  end if;

  select * into t from public.service_tickets where id = p_ticket_id;
  if not found then raise exception 'start_travel: job not found'; end if;

  select * into a from public.appointments x
   where x.ticket_id = p_ticket_id and x.technician_id = v_tech and x.status = 'scheduled'
   order by x.created_at desc limit 1
   for update;
  if not found then raise exception 'start_travel: this job is not assigned to you'; end if;
  if t.status::text <> 'assigned' then
    raise exception 'start_travel: travel can only be started for an assigned job';
  end if;

  if a.travel_started_at is not null then
    return jsonb_build_object('started_at', a.travel_started_at, 'already_started', true);
  end if;

  update public.appointments set travel_started_at = v_now where id = a.id;

  select s.automation_default_travel_eta_minutes into v_eta from public.settings s where s.org_id = t.org_id;
  begin
    perform public.automation_emit(t.org_id, 'technician.on_the_way', 'ticket', t.id, t.customer_id, 'on_the_way@' || a.id::text,
      jsonb_build_object('technician_id', v_tech, 'eta_minutes', coalesce(v_eta, 30), 'ticket_type', t.type::text));
  exception when others then
    perform public._automation_log_error(t.org_id, 'start_travel', 'technician.on_the_way', 'ticket', t.id, sqlstate, sqlerrm);
  end;

  return jsonb_build_object('started_at', v_now, 'already_started', false);
end;
$$;
revoke all on function public.start_travel(uuid) from public, anon;
grant execute on function public.start_travel(uuid) to authenticated, service_role;

update public.automation_events set has_emitter = true where event_key = 'technician.on_the_way';
