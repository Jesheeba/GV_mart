-- Time-aware customerBusy fix (urgent, 2026-11-02).
--
-- Live-pinned sha256 (CR-tolerant, pg_get_functiondef) of
-- assign_ticket_technician before this change: 469dae2fc0211555056c720bfe9af164687f048d6c1ab27dd9ef63c670cf63be
-- (from gv-mart/supabase/migrations/20261016100000_amc_cancel_visit_scheduling_overlap.sql:398-497,
-- the latest live CREATE OR REPLACE -- superseded by several earlier
-- redefinitions, none touched by this migration).
--
-- ROOT CAUSE (reproduced live, Playwright + a direct rolled-back RPC call
-- against a real appointment, 2026-11-02): the customerBusy check --
--   select a.id into v_customer_conflict_id
--   from appointments a join service_tickets st on st.id = a.ticket_id
--   where st.customer_id = v_ticket.customer_id
--     and a.status in ('scheduled', 'in_progress')
--     and a.id <> p_appointment_id and st.id <> v_ticket.id;
-- -- has NO time comparison at all. A customer with ANY other open
-- appointment, on ANY day, blocks every subsequent assignment for them --
-- this is the exact "was: any open appointment" bug the TECHNICIAN check
-- (_tech_conflict_appt) was already fixed for in this same source
-- migration (20261016100000); the customer check was never given the same
-- treatment.
--
-- FIX: new helper public._customer_conflict_appt(), an exact mirror of the
-- already-live, already-reviewed _tech_conflict_appt() -- same
-- _appt_range()/tstzrange('[)')/&&  end-exclusive overlap test, same
-- _ticket_minutes() duration logic -- joined through service_tickets to
-- match on customer_id instead of technician_id. assign_ticket_technician
-- is updated to call it instead of the blunt any-day select. Every other
-- line of assign_ticket_technician (org/permission checks, product check,
-- exemption-window check, technician-conflict check and its p_force
-- override, the notification/SLA logic) is byte-for-byte unchanged from
-- the live pin above.
--
-- Rule (per owner instruction): the customer is busy only if another open
-- appointment of the SAME customer OVERLAPS this one in time (end-exclusive
-- ranges, same duration logic as the technician check). A job on another
-- day never blocks. p_force still bypasses it exactly as before. The error
-- payload still returns conflict_appointment_id so the frontend can name
-- the conflicting job and time (already wired, no frontend change needed).
--
-- NOT APPLIED. Needs: rehearsal + DRYRUN-OK (ONE DO block, RAISE EXCEPTION
-- 'RESULTS'), independent before/after proof, fresh independent
-- string-literal review, fresh independent security review, an exercised
-- rollback, an anon-exposure diff, live-definition pin re-checked at apply
-- time, and the owner's typed APPROVED.

create or replace function public._customer_conflict_appt(
  p_customer uuid,
  p_scheduled timestamp with time zone,
  p_minutes integer,
  p_exclude uuid default null
)
returns uuid
language sql
stable security definer
set search_path to 'public'
as $function$
  select a.id from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  where st.customer_id = p_customer
    and a.status in ('scheduled', 'in_progress')
    and (p_exclude is null or a.id <> p_exclude)
    and public._appt_range(a.scheduled_at, a.ends_at)
        && public._appt_range(p_scheduled, case when p_scheduled is null then null else p_scheduled + make_interval(mins => greatest(coalesce(p_minutes, 60), 1)) end)
  order by a.scheduled_at nulls first
  limit 1
$function$;

revoke all on function public._customer_conflict_appt(uuid, timestamp with time zone, integer, uuid) from public, anon, authenticated;
grant execute on function public._customer_conflict_appt(uuid, timestamp with time zone, integer, uuid) to service_role;

create or replace function public.assign_ticket_technician(p_appointment_id uuid, p_technician_id uuid, p_force boolean DEFAULT false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org_id uuid;
  v_appointment appointments;
  v_ticket service_tickets;
  v_conflict_appt_id uuid;
  v_customer_conflict_id uuid;
  v_settings settings;
  v_sla_hours numeric;
begin
  if not public.is_ops_staff() then
    raise exception 'assign_ticket_technician: only master or operation_admin may assign';
  end if;

  select * into v_appointment from public.appointments where id = p_appointment_id;
  if v_appointment.id is null then
    raise exception 'assign_ticket_technician: appointment % not found', p_appointment_id;
  end if;
  v_org_id := v_appointment.org_id;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'assign_ticket_technician: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = v_org_id) then
    raise exception 'assign_ticket_technician: technician % not found', p_technician_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_appointment.ticket_id;

  if v_ticket.product_id is null and v_ticket.unlisted_product_name is null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.productRequired');
  end if;

  if v_appointment.scheduled_at is not null and v_appointment.available_from is not null and v_appointment.available_to is not null then
    if exists (
      select 1
      from jsonb_array_elements(
        public._customer_exemption_blocks(v_org_id, v_ticket.customer_id, (v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date)
      ) as blk
      where (blk ->> 'start')::time < v_appointment.available_to
        and (blk ->> 'end')::time > v_appointment.available_from
    ) then
      return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.exemptionWindowConflict');
    end if;
  end if;

  -- conflict = another open appointment of this technician at an OVERLAPPING time (was: any open appointment)
  v_conflict_appt_id := public._tech_conflict_appt(p_technician_id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), p_appointment_id);

  if v_conflict_appt_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.technicianBusy', 'conflict_appointment_id', v_conflict_appt_id
    );
  end if;

  -- Urgent fix (2026-11-02): conflict = another open appointment of this
  -- CUSTOMER at an OVERLAPPING time (was: any open appointment, any day --
  -- the same blunt pattern the technician check above was already fixed
  -- for, mirrored here via the same _appt_range/&&/_ticket_minutes logic).
  v_customer_conflict_id := public._customer_conflict_appt(v_ticket.customer_id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), p_appointment_id);

  if v_customer_conflict_id is not null and not p_force then
    return jsonb_build_object(
      'assigned', false, 'reason_key', 'service.assign.customerBusy', 'conflict_appointment_id', v_customer_conflict_id
    );
  end if;

  if p_force and v_conflict_appt_id is not null then
    update public.appointments set technician_id = null where id = v_conflict_appt_id;
    update public.service_tickets st set status = 'open'
      from public.appointments a where a.id = v_conflict_appt_id and st.id = a.ticket_id;
  end if;

  update public.appointments set technician_id = p_technician_id, follow_up_flagged_at = null where id = p_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_appointment.ticket_id and status = 'open';

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select v_org_id, p.id, 'appointment_assigned', 'Job assigned', format('Ticket %s assigned to you.', v_appointment.ticket_id), p_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  select * into v_settings from public.settings where org_id = v_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = greatest(now(), coalesce(v_appointment.scheduled_at, now())) + v_sla_hours * interval '1 hour'
  where id = v_appointment.ticket_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$function$;

-- Grants unchanged from live.
revoke all on function public.assign_ticket_technician(uuid, uuid, boolean) from public, anon;
grant execute on function public.assign_ticket_technician(uuid, uuid, boolean) to authenticated, service_role;
