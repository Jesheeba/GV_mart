-- AMC: cancel a contract, schedule visits properly, and stop treating a technician as "busy for every date" (2026-10-15)
-- batch-2 item 1.  Design: gv-mart/docs/plan-batch2-design.md section 3.
--
-- What was wrong (live):
--   * every visit was stamped at a hard-coded 09:00 (not the master's working hours), Sundays were not rolled to a working day,
--     and `12 / visits_per_year` was integer division;
--   * visits were assigned at purchase time and a technician with ANY open appointment, of any date, counted as busy
--     (a unique index enforced the same thing), so one far-future AMC visit blocked the technician from every other job;
--   * the SLA was counted from the moment of assignment, so a visit scheduled months ahead was already "breached";
--   * there was no way to cancel an AMC contract.
-- What this does (all additive / phased, nothing is deleted):
--   1. amc_contracts.cancelled_at/cancelled_by/cancel_reason + cancel_amc_contract() (master only). A cancelled contract keeps its
--      row and history, gets status 'expired' (so every existing status filter already ignores it), its not-yet-started visit
--      tickets are cancelled and their technicians freed. refresh_amc_statuses leaves cancelled contracts alone.
--   2. visit scheduling helpers: month offset round(12 * i / visits_per_year), roll to the next working day (settings.lead_work_days),
--      start at settings.work_start with the available window work_start..work_end (the customer-side booking model).
--      All five generators (sell_amc_plan, sell_amc_plan_onsite, renew_amc_plan, create_sale AMC add-on and warranty visits,
--      register_product_via_qr) use them.
--   3. time-aware technician overlap: appointments.ends_at (scheduled_at + the ticket's duration, default from settings) with an
--      EXCLUDE constraint per technician on the time range. The old one-open-appointment-per-technician unique index is replaced
--      by it plus a one-untimed-job index. Assignment functions test overlap, not "has any open appointment".
--   4. SLA for an assigned appointment counts from max(now, visit time), not from the moment of assignment.
-- Bodies below are the LIVE definitions (2026-10-15); each differs from live only by the edits described above.

create extension if not exists btree_gist with schema extensions;

-- 1. cancel support ----------------------------------------------------------------------------------------------
alter table public.amc_contracts add column cancelled_at timestamptz;
alter table public.amc_contracts add column cancelled_by uuid references public.profiles (id) on delete set null;
alter table public.amc_contracts add column cancel_reason text;
alter table public.amc_contracts add constraint amc_contracts_cancel_reason_required
  check (cancelled_at is null or nullif(btrim(cancel_reason), '') is not null);

create function public.cancel_amc_contract(p_contract_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_c public.amc_contracts;
  v_tickets uuid[];
  v_cancelled integer := 0;
  v_kept integer := 0;
begin
  if not public.is_master() then
    raise exception 'cancel_amc_contract: only the master may cancel an AMC contract';
  end if;
  select * into v_c from public.amc_contracts where id = p_contract_id;
  if v_c.id is null then
    raise exception 'cancel_amc_contract: contract % not found', p_contract_id;
  end if;
  if v_c.org_id is distinct from public.current_org_id() then
    raise exception 'cancel_amc_contract: org mismatch';
  end if;
  if v_c.cancelled_at is not null then
    raise exception 'cancel_amc_contract: contract is already cancelled';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'cancel_amc_contract: a cancellation reason is required';
  end if;

  select coalesce(array_agg(t.id), '{}') into v_tickets
  from public.service_tickets t where t.contract_id = v_c.id and t.status in ('open', 'assigned');
  v_cancelled := coalesce(array_length(v_tickets, 1), 0);
  select count(*) into v_kept from public.service_tickets t
  where t.contract_id = v_c.id and t.status in ('in_progress', 'completed');

  update public.service_tickets
  set status = 'cancelled', cancellation_reason = 'AMC contract cancelled: ' || btrim(p_reason),
      cancelled_at = now(), cancelled_by = auth.uid(), updated_at = now()
  where id = any (v_tickets);

  update public.appointments
  set status = 'cancelled', technician_id = null, updated_at = now()
  where ticket_id = any (v_tickets) and status in ('scheduled', 'in_progress');

  -- stale "needs manual assignment" alerts for the cancelled visits are no longer actionable
  update public.notifications set is_read = true
  where type = 'ticket_unassigned' and ref_id = any (v_tickets) and is_read = false;

  update public.amc_contracts
  set cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = btrim(p_reason), status = 'expired', updated_at = now()
  where id = v_c.id;

  return jsonb_build_object('contract_id', v_c.id, 'visits_cancelled', v_cancelled, 'visits_kept', v_kept);
end;
$$;
revoke all on function public.cancel_amc_contract(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_amc_contract(uuid, text) to authenticated, service_role;

-- 2. visit scheduling helpers --------------------------------------------------------------------------------------
create function public._visit_month_offset(p_visits_per_year integer, p_i integer)
returns integer language sql immutable as $$
  select round(12.0 * p_i / greatest(coalesce(p_visits_per_year, 1), 1))::integer
$$;

-- the visit date itself, or the next working day (settings.lead_work_days, the master-editable working week)
create function public._visit_working_day(p_org uuid, p_date date)
returns date language sql stable security definer set search_path = public as $$
  select case when public._lead_is_working_day(p_org, p_date) then p_date else public.lead_next_working_day(p_org, p_date) end
$$;

create function public._visit_start_ts(p_org uuid, p_date date)
returns timestamptz language sql stable security definer set search_path = public as $$
  select (p_date + coalesce((select s.work_start from public.settings s where s.org_id = p_org), time '09:15')) at time zone 'Asia/Kolkata'
$$;
create function public._visit_window_from(p_org uuid)
returns time language sql stable security definer set search_path = public as $$
  select coalesce((select s.work_start from public.settings s where s.org_id = p_org), time '09:15')
$$;
create function public._visit_window_to(p_org uuid)
returns time language sql stable security definer set search_path = public as $$
  select coalesce((select s.work_end from public.settings s where s.org_id = p_org), time '17:30')
$$;
revoke execute on function public._visit_month_offset(integer, integer), public._visit_working_day(uuid, date), public._visit_start_ts(uuid, date),
  public._visit_window_from(uuid), public._visit_window_to(uuid) from public, anon, authenticated;
grant execute on function public._visit_month_offset(integer, integer), public._visit_working_day(uuid, date), public._visit_start_ts(uuid, date),
  public._visit_window_from(uuid), public._visit_window_to(uuid) to service_role;

-- 3. time-aware technician overlap ---------------------------------------------------------------------------------
-- minutes a ticket occupies: its own estimate, else the master's default for its type, else 60
create function public._ticket_minutes(p_ticket_id uuid)
returns integer language sql stable security definer set search_path = public as $$
  select greatest(15, coalesce(
    t.estimated_duration_minutes,
    case t.type::text
      when 'paid' then s.default_duration_paid_minutes
      when 'warranty' then s.default_duration_warranty_minutes
      when 'amc' then s.default_duration_amc_minutes
      when 'installation' then s.default_duration_installation_minutes
      else null end,
    60))
  from public.service_tickets t left join public.settings s on s.org_id = t.org_id
  where t.id = p_ticket_id
$$;

alter table public.appointments add column ends_at timestamptz;

create function public._trg_appointment_ends_at()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.scheduled_at is null then
    new.ends_at := null;
  else
    new.ends_at := new.scheduled_at + make_interval(mins => coalesce(public._ticket_minutes(new.ticket_id), 60));
  end if;
  return new;
end;
$$;
revoke execute on function public._trg_appointment_ends_at() from public, anon, authenticated;
create trigger appointments_ends_at before insert or update of scheduled_at, ticket_id on public.appointments
  for each row execute function public._trg_appointment_ends_at();

-- the 7-ish existing appointments (bumps their updated_at; no other effect)
update public.appointments a
set ends_at = a.scheduled_at + make_interval(mins => coalesce(public._ticket_minutes(a.ticket_id), 60))
where a.scheduled_at is not null and a.ends_at is null;

-- an appointment with no time ('always' mode) occupies the IST day it is worked on
create function public._appt_range(p_start timestamptz, p_end timestamptz)
returns tstzrange language sql stable as $$
  select case when p_start is null then
      tstzrange(
        (date_trunc('day', now() at time zone 'Asia/Kolkata')) at time zone 'Asia/Kolkata',
        (date_trunc('day', now() at time zone 'Asia/Kolkata') + interval '1 day') at time zone 'Asia/Kolkata', '[)')
    else tstzrange(p_start, coalesce(p_end, p_start + interval '60 minutes'), '[)') end
$$;

-- the first open appointment of this technician that overlaps [scheduled, scheduled + minutes), or NULL
create function public._tech_conflict_appt(p_tech uuid, p_scheduled timestamptz, p_minutes integer, p_exclude uuid default null)
returns uuid language sql stable security definer set search_path = public as $$
  select a.id from public.appointments a
  where a.technician_id = p_tech
    and a.status in ('scheduled', 'in_progress')
    and (p_exclude is null or a.id <> p_exclude)
    and public._appt_range(a.scheduled_at, a.ends_at)
        && public._appt_range(p_scheduled, case when p_scheduled is null then null else p_scheduled + make_interval(mins => greatest(coalesce(p_minutes, 60), 1)) end)
  order by a.scheduled_at nulls first
  limit 1
$$;
create function public._tech_busy_at(p_tech uuid, p_scheduled timestamptz, p_minutes integer, p_exclude uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select public._tech_conflict_appt(p_tech, p_scheduled, p_minutes, p_exclude) is not null
$$;
revoke execute on function public._appt_range(timestamptz, timestamptz), public._tech_conflict_appt(uuid, timestamptz, integer, uuid),
  public._tech_busy_at(uuid, timestamptz, integer, uuid), public._ticket_minutes(uuid) from public, anon, authenticated;
grant execute on function public._appt_range(timestamptz, timestamptz), public._tech_conflict_appt(uuid, timestamptz, integer, uuid),
  public._tech_busy_at(uuid, timestamptz, integer, uuid), public._ticket_minutes(uuid) to service_role;

-- swap the blunt index for the time-range constraint (+ keep "one job with no time" per technician)
drop index if exists public.appointments_one_open_per_technician_idx;
create unique index appointments_one_open_untimed_per_technician_idx on public.appointments (technician_id)
  where status in ('scheduled', 'in_progress') and technician_id is not null and scheduled_at is null;
alter table public.appointments add constraint appointments_technician_no_overlap
  exclude using gist (technician_id with =, tstzrange(scheduled_at, ends_at, '[)') with &&)
  where (status in ('scheduled', 'in_progress') and technician_id is not null and scheduled_at is not null and ends_at is not null);


-- _auto_assign_ticket_internal
create or replace function public._auto_assign_ticket_internal(p_ticket_id uuid, p_org_id uuid, p_skip_rating_logic boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ticket service_tickets;
  v_appointment appointments;
  v_addr addresses;
  v_tech_id uuid;
  v_tech_count integer;
  v_prior_ticket_id uuid;
  v_prior_tech_id uuid;
  v_prior_stars numeric(2,1);
  v_settings settings;
  v_sla_hours numeric;
  v_tech_name text;
  v_channel_suffix text;
begin
  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % not found', p_ticket_id;
  end if;

  -- Only WhatsApp gets a marker, matching TicketBadges.tsx's ChannelBadge
  -- convention (only WhatsApp visually stands out; the other 4 channel
  -- values are treated as equivalent "not WhatsApp" origins).
  v_channel_suffix := case when v_ticket.channel = 'whatsapp' then ' (via WhatsApp)' else '' end;

  select * into v_appointment from public.appointments
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress')
  order by created_at desc limit 1;
  if v_appointment.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % has no open appointment to assign', p_ticket_id;
  end if;
  if v_appointment.technician_id is not null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyAssigned');
  end if;

  if v_ticket.product_id is null and v_ticket.unlisted_product_name is null then
    -- 2026-08-31 fix: this used to return here with ZERO notification â€”
    -- a booking could complete and then sit invisible to staff forever if
    -- it somehow reached this state. Reuses the same 'ticket_unassigned'
    -- type as the "no technician available" case below (same staff
    -- action needed: go look at this ticket), not a new type value.
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment' || v_channel_suffix,
      format('Ticket %s has no product on file and cannot be auto-assigned â€” add a product to proceed.', p_ticket_id), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.productRequired');
  end if;

  if v_ticket.address_id is not null then
    select * into v_addr from public.addresses where id = v_ticket.address_id;
  end if;

  if not p_skip_rating_logic then
    select st2.id into v_prior_ticket_id
    from public.service_tickets st2
    where st2.customer_id = v_ticket.customer_id and st2.id <> p_ticket_id and st2.status = 'completed'
    order by st2.updated_at desc limit 1;

    if v_prior_ticket_id is not null then
      select sv.technician_id, r.stars into v_prior_tech_id, v_prior_stars
      from public.service_visits sv
      left join public.ratings r on r.visit_id = sv.id
      where sv.ticket_id = v_prior_ticket_id
      order by sv.timer_start desc limit 1;
    end if;

    if v_prior_stars >= 4 and v_prior_tech_id is not null then
      select t.id into v_tech_id
      from public.technicians t
      where t.id = v_prior_tech_id and t.org_id = p_org_id and t.is_active = true
        and exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not public._tech_busy_at(t.id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), v_appointment.id)
      for update of t skip locked;
    elsif v_prior_stars is not null and v_prior_stars <= 3 then
      select t.id into v_tech_id
      from public.technicians t
      where t.org_id = p_org_id and t.is_active = true
        and exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not public._tech_busy_at(t.id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), v_appointment.id)
      order by (
        select avg(r2.stars) from public.ratings r2
        join public.service_visits sv2 on sv2.id = r2.visit_id
        where sv2.technician_id = t.id
      ) desc nulls last
      for update of t skip locked
      limit 1;
    end if;
  end if;

  if v_tech_id is null then
    select t.id into v_tech_id
    from public.technicians t
    left join lateral (
      select tl.lat, tl.lng from public.technician_locations tl
      where tl.technician_id = t.id order by tl.recorded_at desc limit 1
    ) loc on true
    where t.org_id = p_org_id
      and t.is_active = true
      and (
        (v_appointment.scheduled_at is not null and (v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date > (now() at time zone 'Asia/Kolkata')::date)
        or exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
            and a.check_in_at is not null and a.check_out_at is null
        )
      )
      and (
        v_appointment.scheduled_at is null
        or (v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date <= (now() at time zone 'Asia/Kolkata')::date
        or not exists (
          select 1 from public.technician_availability ta
          where ta.technician_id = t.id
            and ta.date = (v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date
            and ta.status = 'leave'
        )
      )
      -- busy only at an OVERLAPPING time (was: any open appointment of any date)
      and not public._tech_busy_at(t.id, v_appointment.scheduled_at, public._ticket_minutes(v_ticket.id), v_appointment.id)
      and coalesce((
        select sum(public._ticket_minutes(st2.id))
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = t.id
          and a2.status in ('scheduled', 'in_progress')
          and (a2.scheduled_at at time zone 'Asia/Kolkata')::date = coalesce((v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date, (now() at time zone 'Asia/Kolkata')::date)
      ), 0) + public._ticket_minutes(v_ticket.id) <= t.daily_capacity_minutes
    order by
      case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
        then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
        else null
      end asc nulls last,
      (
        select count(*) from public.appointments a2
        where a2.technician_id = t.id and (a2.scheduled_at at time zone 'Asia/Kolkata')::date = coalesce((v_appointment.scheduled_at at time zone 'Asia/Kolkata')::date, (now() at time zone 'Asia/Kolkata')::date)
      ) asc,
      t.created_at asc
    for update of t skip locked
    limit 1;
  end if;

  if v_tech_id is null then
    select count(*) into v_tech_count
    from public.technicians t
    where t.org_id = p_org_id and t.is_active = true
      and exists (
        select 1 from public.attendance a
        where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
          and a.check_in_at is not null and a.check_out_at is null
      );
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment' || v_channel_suffix,
      format('No free technician is available for ticket %s (%s checked in today).', p_ticket_id, v_tech_count), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id, follow_up_flagged_at = null where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = greatest(now(), coalesce(v_appointment.scheduled_at, now())) + v_sla_hours * interval '1 hour'
  where id = p_ticket_id;

  select p.full_name into v_tech_name
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'ticket_auto_assigned', 'Ticket auto-assigned' || v_channel_suffix,
    format('%s auto-assigned to %s.', coalesce(v_ticket.name_of_complaint, 'Ticket ' || p_ticket_id), coalesce(v_tech_name, 'a technician')),
    p_ticket_id);

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$function$;

-- assign_ticket_technician
create or replace function public.assign_ticket_technician(p_appointment_id uuid, p_technician_id uuid, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  select a.id into v_customer_conflict_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  where st.customer_id = v_ticket.customer_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id
    and st.id <> v_ticket.id;

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

-- _auto_assign_next_ticket_to_technician
create or replace function public._auto_assign_next_ticket_to_technician(p_org_id uuid, p_technician_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tech technicians;
  v_appointment_id uuid;
  v_ticket_id uuid;
  v_ticket service_tickets;
  v_settings settings;
  v_sla_hours numeric;
  v_tech_name text;
begin
  select * into v_tech from public.technicians where id = p_technician_id and org_id = p_org_id;
  if v_tech.id is null or not v_tech.is_active then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.technicianInactive');
  end if;

  -- free for the next job unless something overlaps right now (was: any open appointment of any date)
  if public._tech_busy_at(p_technician_id, now(), 1, null) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyBusy');
  end if;

  if not exists (
    select 1 from public.attendance a
    where a.technician_id = p_technician_id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
      and a.check_in_at is not null and a.check_out_at is null
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.notPresent');
  end if;

  select a.id, a.ticket_id into v_appointment_id, v_ticket_id
  from public.appointments a
  join public.service_tickets st on st.id = a.ticket_id
  left join public.addresses addr on addr.id = st.address_id
  left join lateral (
    select tl.lat, tl.lng from public.technician_locations tl
    where tl.technician_id = p_technician_id order by tl.recorded_at desc limit 1
  ) loc on true
  where a.org_id = p_org_id
    and a.technician_id is null
    and a.status in ('scheduled', 'in_progress')
    and st.status = 'open'
    and (st.product_id is not null or st.unlisted_product_name is not null)
    and not public._tech_busy_at(p_technician_id, coalesce(a.scheduled_at, now()), public._ticket_minutes(st.id), a.id)
    and (a.scheduled_at is null or (a.scheduled_at at time zone 'Asia/Kolkata')::date <= (now() at time zone 'Asia/Kolkata')::date)
    and coalesce((
      select sum(public._ticket_minutes(st2.id))
      from public.appointments a2
      join public.service_tickets st2 on st2.id = a2.ticket_id
      where a2.technician_id = p_technician_id
        and a2.status in ('scheduled', 'in_progress')
        and (a2.scheduled_at at time zone 'Asia/Kolkata')::date = coalesce((a.scheduled_at at time zone 'Asia/Kolkata')::date, (now() at time zone 'Asia/Kolkata')::date)
    ), 0) + public._ticket_minutes(st.id) <= v_tech.daily_capacity_minutes
  order by
    case st.priority when 'very_urgent' then 0 when 'urgent' then 1 else 2 end asc,
    case when loc.lat is not null and addr.lat is not null and addr.lng is not null
      then point(loc.lng, loc.lat) <-> point(addr.lng, addr.lat)
      else null
    end asc nulls last,
    coalesce(a.scheduled_at, st.created_at) asc
  for update of a skip locked
  limit 1;

  if v_appointment_id is null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneWaiting');
  end if;

  update public.appointments set technician_id = p_technician_id, follow_up_flagged_at = null where id = v_appointment_id;
  update public.service_tickets set status = 'assigned' where id = v_ticket_id;

  select * into v_ticket from public.service_tickets where id = v_ticket_id;
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(),
      sla_due_at = (select greatest(now(), coalesce(a9.scheduled_at, now())) from public.appointments a9 where a9.id = v_appointment_id)
                   + v_sla_hours * interval '1 hour'
  where id = v_ticket_id;

  select p.full_name into v_tech_name
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', v_ticket_id), v_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'ticket_auto_assigned', 'Ticket auto-assigned',
    format('%s auto-assigned to %s.', coalesce(v_ticket.name_of_complaint, 'Ticket ' || v_ticket_id), coalesce(v_tech_name, 'a technician')),
    v_ticket_id);

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id, 'appointment_id', v_appointment_id, 'ticket_id', v_ticket_id);
end;
$function$;

-- _next_ticket_available_for_technician
create or replace function public._next_ticket_available_for_technician(p_org_id uuid, p_technician_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    join public.technicians t on t.id = p_technician_id
    where a.org_id = p_org_id
      and a.technician_id is null
      and a.status in ('scheduled', 'in_progress')
      and st.status = 'open'
      and (st.product_id is not null or st.unlisted_product_name is not null)
      and not public._tech_busy_at(p_technician_id, now(), 1, null)
      and not public._tech_busy_at(p_technician_id, coalesce(a.scheduled_at, now()), public._ticket_minutes(st.id), a.id)
      and (a.scheduled_at is null or (a.scheduled_at at time zone 'Asia/Kolkata')::date <= (now() at time zone 'Asia/Kolkata')::date)
      and coalesce((
        select sum(public._ticket_minutes(st2.id))
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = p_technician_id
          and a2.status in ('scheduled', 'in_progress')
          and (a2.scheduled_at at time zone 'Asia/Kolkata')::date = coalesce((a.scheduled_at at time zone 'Asia/Kolkata')::date, (now() at time zone 'Asia/Kolkata')::date)
      ), 0) + public._ticket_minutes(st.id) <= t.daily_capacity_minutes
  );
$function$;

-- sell_amc_plan
create or replace function public.sell_amc_plan(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_years integer DEFAULT NULL::integer, p_referred_by_technician_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_plan amc_plans;
  v_years integer;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
  v_lead_id uuid; -- REFERRAL (new): resolved technician referral, if any
  v_customer_name text;
begin
  if not (public.is_ops_staff() or public.is_sales_staff()) then
    raise exception 'sell_amc_plan: only master, operation_admin, or sales_admin may sell an AMC plan';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan: org mismatch';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'sell_amc_plan: years must be greater than zero';
  end if;

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'AMC sale, referred by technician');
  end if;

  v_expiry := p_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_visit_date := p_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := p_start_date + make_interval(months => public._visit_month_offset(v_plan.visits_per_year, i));
    exit when v_visit_date > v_expiry;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, p_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'call', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled')
    returning id into v_appointment_id;

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$function$;

-- sell_amc_plan_onsite
create or replace function public.sell_amc_plan_onsite(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_method payment_method, p_txn_id text DEFAULT NULL::text, p_payment_description text DEFAULT NULL::text, p_amount_paid numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tech_id uuid;
  v_customer_name text;
  v_lead_id uuid;
  v_settings settings;
  v_plan amc_plans;
  v_effective_price numeric(12, 2);
  v_discount numeric(12, 2) := 0;
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'sell_amc_plan_onsite: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan_onsite: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'sell_amc_plan_onsite: customer % not found in org %', p_customer_id, p_org_id;
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan_onsite: AMC plans are only sold on RO products';
  end if;
  if p_payment_method = 'transfer' and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'sell_amc_plan_onsite: bank transfer requires a transaction ID and description';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan_onsite: plan % not found', p_plan_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'sell_amc_plan_onsite: no settings row for org %', p_org_id;
  end if;

  select name into v_customer_name from public.customers where id = p_customer_id;
  insert into public.leads (org_id, customer_id, name, source, status, owner_id)
  values (p_org_id, p_customer_id, coalesce(v_customer_name, 'On-site AMC customer'), 'field', 'won', v_tech_id)
  returning id into v_lead_id;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'converted', format('On-site AMC sale (%s) by technician', v_plan.name));

  v_effective_price := coalesce(v_plan.price_per_year * v_plan.years, v_plan.price);
  v_gst := round(v_effective_price * v_settings.gst_rate / 100, 2);
  v_total := v_effective_price + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'sell_amc_plan_onsite: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'sell_amc_plan_onsite: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'amc', v_effective_price, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid, auth.uid()
  ) returning * into v_invoice;

  v_expiry := (now() at time zone 'Asia/Kolkata')::date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
  values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, (now() at time zone 'Asia/Kolkata')::date,
    v_expiry, 'active', (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_interval_months), v_invoice.id
  )
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_invoice.id, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_visit_date := (now() at time zone 'Asia/Kolkata')::date;
  for i in 1..v_total_visits loop
    v_visit_date := (now() at time zone 'Asia/Kolkata')::date + make_interval(months => public._visit_month_offset(v_plan.visits_per_year, i));
    exit when v_visit_date > v_expiry;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, p_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'field', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold on-site',
    format('%s AMC contract sold on-site by a technician, %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)),
    v_contract_id
  );

  return jsonb_build_object(
    'invoice_id', v_invoice.id,
    'contract_id', v_contract_id,
    'ticket_ids', to_jsonb(v_ticket_ids),
    'expiry_date', v_expiry,
    'lead_id', v_lead_id
  );
end;
$function$;

-- renew_amc_plan
create or replace function public.renew_amc_plan(p_org_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_reference text, p_years integer DEFAULT NULL::integer, p_referred_by_technician_name text DEFAULT NULL::text, p_address_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_plan amc_plans;
  v_years integer;
  v_existing amc_contracts;
  v_settings settings;
  v_start_date date;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_contract_id uuid;
  v_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'renew_amc_plan: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'renew_amc_plan: org mismatch';
  end if;
  if p_payment_reference is null or btrim(p_payment_reference) = '' then
    raise exception 'renew_amc_plan: a payment reference is required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'renew_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'renew_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    select count(*), min(t.id) into v_tech_match_count, v_tech_id
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count <> 1 then
      v_tech_id := null;
    end if;
  end if;

  if v_tech_id is not null then
    select name into v_customer_name from public.customers where id = v_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', v_tech_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', format('AMC self-service purchase, referred by %s', p_referred_by_technician_name));
  end if;

  v_start_date := greatest((now() at time zone 'Asia/Kolkata')::date, coalesce(v_existing.expiry_date, (now() at time zone 'Asia/Kolkata')::date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_visit_date := v_start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_start_date + make_interval(months => public._visit_month_offset(v_plan.visits_per_year, i));
    exit when v_visit_date > v_expiry;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, v_total_visits), v_plan.name,
      'amc', 'normal', 'open', 'customer_app', v_contract_id, v_lead_id -- FINDER CREDIT
    )
    returning id into v_ticket_id;
    v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);
  end loop;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) â€” payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$function$;

-- create_sale
create or replace function public.create_sale(p_org_id uuid, p_customer_id uuid, p_cart jsonb, p_quotation_id uuid DEFAULT NULL::uuid, p_redeem_points integer DEFAULT 0, p_referred_by_technician_id uuid DEFAULT NULL::uuid, p_amount_paid numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_settings settings;
  v_discount_percent numeric(5, 2);
  v_payment_method payment_method;
  v_spare_invoice invoices;
  v_product_invoice invoices;
  v_amc_invoice invoices;
  v_primary_invoice_id uuid;
  v_combined_subtotal numeric(12, 2);
  v_gift_excluded_amount numeric(12, 2);
  v_gift_id uuid;
  v_gift gifts;
  v_approval_id uuid;
  v_item record;
  v_warranty_id uuid;
  v_ticket_id uuid;
  v_tech_id uuid;
  v_amc_product_id uuid;
  v_amc_plan_id uuid;
  v_amc_plan amc_plans;
  v_amc_discount numeric(12, 2);
  v_amc_gst numeric(12, 2);
  v_amc_total numeric(12, 2);
  v_amc_contract_id uuid;
  v_amc_expiry date;
  v_amc_interval_months integer;
  v_amc_total_visits integer;
  v_amc_visit_date date;
  v_amc_ticket_id uuid;
  v_amc_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_warranty_ids uuid[] := '{}';
  v_has_amc boolean;
  v_redeem_points integer := 0;
  v_redeem_balance integer;
  v_redeem_amount numeric(12, 2) := 0;
  v_primary_invoice_total numeric(12, 2);
  v_warranty warranties;
  v_warranty_address_id uuid;
  v_warranty_total_visits integer;
  v_warranty_visit_date date;
  v_warranty_ticket_id uuid;
  v_amc_effective_price numeric(12, 2);
  v_lead_id uuid; -- FINDER CREDIT: source lead behind p_quotation_id, if any
  v_customer_name text; -- REFERRAL: only looked up if p_referred_by_technician_id is used
  v_combined_total numeric(12, 2); -- AMOUNT TRACKING: sum of every invoice's *current* total, after gift/redeem adjustments
  v_amount_paid_remaining numeric(12, 2);
  v_pay_invoice_id uuid;
  v_pay_invoice_total numeric(12, 2);
  v_pay_amount numeric(12, 2);
begin
  if not public.is_sales_staff() then
    raise exception 'create_sale: only master or sales_admin may create a sale';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_sale: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_sale: customer % not found in org %', p_customer_id, p_org_id;
  end if;

  if p_quotation_id is not null then
    select lead_id into v_lead_id from public.quotations where id = p_quotation_id and org_id = p_org_id;
  end if;

  if v_lead_id is null and p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Sales customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Walk-in sale, referred by technician');
  end if;

  v_has_amc := p_cart -> 'amc' is not null and p_cart -> 'amc' <> 'null'::jsonb;
  if coalesce(jsonb_array_length(p_cart -> 'spare_items'), 0) = 0
     and coalesce(jsonb_array_length(p_cart -> 'product_items'), 0) = 0
     and not v_has_amc then
    raise exception 'create_sale: cart is empty';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_sale: no settings row for org %', p_org_id;
  end if;

  v_discount_percent := coalesce((p_cart ->> 'discount_percent')::numeric, 0);
  if v_discount_percent < 0 then
    raise exception 'create_sale: discount cannot be negative';
  end if;
  if v_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_sale: discount % exceeds the admin limit of %', v_discount_percent, v_settings.discount_admin_max;
  end if;

  v_payment_method := nullif(p_cart ->> 'payment_method', '')::payment_method;
  if v_payment_method is null then
    raise exception 'create_sale: payment_method is required';
  end if;
  if v_payment_method = 'transfer'
     and (nullif(p_cart ->> 'txn_id', '') is null or nullif(p_cart ->> 'payment_description', '') is null) then
    raise exception 'create_sale: bank transfer requires a transaction ID and description';
  end if;

  v_redeem_points := coalesce(p_redeem_points, 0);
  if v_redeem_points < 0 then
    raise exception 'create_sale: redeem points cannot be negative';
  end if;
  if v_redeem_points > 0 then
    select coalesce(sum(points), 0) into v_redeem_balance
    from public.referral_points
    where customer_id = p_customer_id and org_id = p_org_id;

    if v_redeem_points > v_redeem_balance then
      raise exception 'create_sale: cannot redeem % referral points â€” customer % has a balance of only %', v_redeem_points, p_customer_id, v_redeem_balance;
    end if;

    v_redeem_amount := round(v_redeem_points * v_settings.referral_point_value, 2);
  end if;

  v_spare_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'spare', p_cart -> 'spare_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  v_product_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'product', p_cart -> 'product_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  if v_product_invoice.id is not null then
    for v_item in
      select * from jsonb_to_recordset(p_cart -> 'product_items')
        as x(item_id uuid, qty integer, warranty boolean, warranty_months integer, installation boolean)
    loop
      if coalesce(v_item.warranty, false) then
        insert into public.warranties (org_id, customer_id, product_id, start_date, expiry_date, invoice_id)
        select p_org_id, p_customer_id, v_item.item_id, (now() at time zone 'Asia/Kolkata')::date,
               (now() at time zone 'Asia/Kolkata')::date + (coalesce(v_item.warranty_months, p.warranty_months) || ' months')::interval,
               v_product_invoice.id
        from public.products p where p.id = v_item.item_id
        returning id into v_warranty_id;
        v_warranty_ids := array_append(v_warranty_ids, v_warranty_id);

        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (
          p_org_id, 'operation_admin', 'warranty_registered', 'Warranty registered',
          format('A warranty was registered from invoice %s.', v_product_invoice.id), v_warranty_id
        );

        select * into v_warranty from public.warranties where id = v_warranty_id;
        select a.id into v_warranty_address_id from public.addresses a
        where a.customer_id = p_customer_id and a.is_primary = true limit 1;

        v_warranty_total_visits := floor(
          (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
            + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
        )::integer;

        v_warranty_visit_date := v_warranty.start_date;
        for i in 1..v_warranty_total_visits loop
          v_warranty_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
          exit when v_warranty_visit_date > v_warranty.expiry_date;
          v_warranty_visit_date := public._visit_working_day(p_org_id, v_warranty_visit_date);

          insert into public.service_tickets (
            org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
            type, priority, status, channel, lead_id, warranty_id
          ) values (
            p_org_id, p_customer_id, v_warranty_address_id, v_item.item_id,
            format('Warranty scheduled service %s of %s', i, v_warranty_total_visits), 'Warranty scheduled service',
            'warranty', 'normal', 'open', 'walk_in', v_lead_id, v_warranty_id -- FINDER CREDIT
          )
          returning id into v_warranty_ticket_id;
          v_ticket_ids := array_append(v_ticket_ids, v_warranty_ticket_id);

          insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_warranty_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_warranty_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

          perform public._auto_assign_ticket_internal(v_warranty_ticket_id, p_org_id, p_skip_rating_logic => true);

          if i = 1 then
            update public.warranties set next_service_date = v_warranty_visit_date where id = v_warranty_id;
          end if;
        end loop;
      end if;

      if coalesce(v_item.installation, false) then
        insert into public.service_tickets (
          org_id, customer_id, product_id, brand_id, model_id,
          name_of_complaint, nature_of_complaint, type, priority, status, channel, invoice_id, lead_id
        )
        select p_org_id, p_customer_id, v_item.item_id, p.brand_id, p.model_id,
               'Installation', 'New product installation', 'installation', 'normal', 'open', 'walk_in', v_product_invoice.id, v_lead_id -- FINDER CREDIT
        from public.products p where p.id = v_item.item_id
        returning id into v_ticket_id;
        v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

        select t.id into v_tech_id
        from public.technicians t
        where t.org_id = p_org_id and t.is_active = true
          and exists (
            select 1 from public.attendance a
            where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
              and a.check_in_at is not null and a.check_out_at is null
          )
          and not public._tech_busy_at(t.id, null, null, null)
        order by t.created_at
        for update skip locked
        limit 1;

        if v_tech_id is not null then
          insert into public.appointments (org_id, ticket_id, technician_id, mode, status)
          values (p_org_id, v_ticket_id, v_tech_id, 'always', 'scheduled');
          update public.service_tickets set status = 'assigned' where id = v_ticket_id;
        else
          insert into public.notifications (org_id, role, type, title, body, ref_id)
          values (
            p_org_id, 'operation_admin', 'installation_unassigned', 'Installation needs manual assignment',
            'No on-duty technician is free right now â€” assign this installation manually.', v_ticket_id
          );
        end if;
      end if;
    end loop;
  end if;

  if v_has_amc then
    v_amc_product_id := (p_cart -> 'amc' ->> 'product_id')::uuid;
    v_amc_plan_id := (p_cart -> 'amc' ->> 'plan_id')::uuid;

    if not exists (select 1 from public.products where id = v_amc_product_id and org_id = p_org_id and category = 'ro') then
      raise exception 'create_sale: AMC add-on is only available on RO products';
    end if;

    select * into v_amc_plan from public.amc_plans where id = v_amc_plan_id and org_id = p_org_id;
    if v_amc_plan is null then
      raise exception 'create_sale: AMC plan % not found', v_amc_plan_id;
    end if;

    v_amc_effective_price := coalesce(v_amc_plan.price_per_year * v_amc_plan.years, v_amc_plan.price);

    v_amc_discount := round(v_amc_effective_price * v_discount_percent / 100, 2);
    v_amc_gst := round((v_amc_effective_price - v_amc_discount) * v_settings.gst_rate / 100, 2);
    v_amc_total := v_amc_effective_price - v_amc_discount + v_amc_gst;

    insert into public.invoices (
      org_id, customer_id, type, subtotal, discount, gst, total,
      payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_effective_price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid', v_amc_total, auth.uid()
    ) returning * into v_amc_invoice;

    v_amc_expiry := (now() at time zone 'Asia/Kolkata')::date + (v_amc_plan.years || ' years')::interval;
    v_amc_interval_months := greatest(1, round(12.0 / v_amc_plan.visits_per_year)::integer);
    v_amc_total_visits := v_amc_plan.years * v_amc_plan.visits_per_year;

    insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
    values (
      p_org_id, p_customer_id, v_amc_product_id, v_amc_plan_id, (now() at time zone 'Asia/Kolkata')::date,
      v_amc_expiry, 'active',
      (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_amc_interval_months),
      v_amc_invoice.id
    )
    returning id into v_amc_contract_id;

    if v_amc_plan.gift_id is not null then
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_amc_invoice.id, v_amc_plan.gift_id);
    end if;

    select a.id into v_amc_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

    v_amc_visit_date := (now() at time zone 'Asia/Kolkata')::date;
    for i in 1..v_amc_total_visits loop
      v_amc_visit_date := (now() at time zone 'Asia/Kolkata')::date + make_interval(months => public._visit_month_offset(v_amc_plan.visits_per_year, i));
      exit when v_amc_visit_date > v_amc_expiry;
      v_amc_visit_date := public._visit_working_day(p_org_id, v_amc_visit_date);

      insert into public.service_tickets (
        org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
        type, priority, status, channel, contract_id, lead_id
      ) values (
        p_org_id, p_customer_id, v_amc_address_id, v_amc_product_id,
        format('AMC scheduled service %s of %s', i, v_amc_total_visits), v_amc_plan.name,
        'amc', 'normal', 'open', 'walk_in', v_amc_contract_id, v_lead_id -- FINDER CREDIT
      )
      returning id into v_amc_ticket_id;
      v_ticket_ids := array_append(v_ticket_ids, v_amc_ticket_id);

      insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_amc_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_amc_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

      perform public._auto_assign_ticket_internal(v_amc_ticket_id, p_org_id, p_skip_rating_logic => true);
    end loop;
  end if;

  v_primary_invoice_id := coalesce(v_product_invoice.id, v_spare_invoice.id, v_amc_invoice.id);
  v_combined_subtotal := coalesce(v_product_invoice.subtotal, 0) + coalesce(v_spare_invoice.subtotal, 0) + coalesce(v_amc_invoice.subtotal, 0);

  v_gift_excluded_amount := 0;
  if v_product_invoice.id is not null then
    select coalesce(sum(p.price * x.qty), 0) into v_gift_excluded_amount
    from jsonb_to_recordset(p_cart -> 'product_items') as x(item_id uuid, qty integer, warranty boolean, warranty_months integer, installation boolean)
    join public.products p on p.id = x.item_id and p.org_id = p_org_id
    where exists (
      select 1 from public.gift_exclusion_products gep
      where gep.org_id = p_org_id and gep.product_id = x.item_id and gep.is_active = true
    );
  end if;

  v_gift_id := nullif(p_cart ->> 'gift_id', '')::uuid;
  if v_gift_id is not null and v_primary_invoice_id is not null then
    select * into v_gift from public.gifts where id = v_gift_id and org_id = p_org_id;
    if v_gift is not null and (v_combined_subtotal - v_gift_excluded_amount) >= v_gift.threshold_amount then
      update public.invoices set gift_id = v_gift_id where id = v_primary_invoice_id;
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_primary_invoice_id, v_gift_id);
    end if;
  end if;

  if v_redeem_points > 0 then
    if v_primary_invoice_id is null then
      raise exception 'create_sale: cannot redeem referral points â€” the cart produced no invoice to apply them to';
    end if;

    select total into v_primary_invoice_total from public.invoices where id = v_primary_invoice_id;
    v_redeem_amount := least(v_redeem_amount, v_primary_invoice_total);

    update public.invoices set total = total - v_redeem_amount where id = v_primary_invoice_id;

    insert into public.referral_points (org_id, customer_id, points, reason, ref_id)
    values (p_org_id, p_customer_id, -v_redeem_points, 'redeemed_on_sale', v_primary_invoice_id);
  end if;

  v_combined_total := 0;
  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_combined_total := v_combined_total + v_pay_invoice_total;
  end loop;

  v_amount_paid_remaining := coalesce(p_amount_paid, v_combined_total);
  if v_amount_paid_remaining < 0 then
    raise exception 'create_sale: amount_paid cannot be negative';
  end if;
  if v_amount_paid_remaining > v_combined_total then
    raise exception 'create_sale: amount_paid (%) cannot exceed the combined invoice total (%)', v_amount_paid_remaining, v_combined_total;
  end if;

  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_pay_amount := least(v_amount_paid_remaining, v_pay_invoice_total);
    update public.invoices
      set amount_paid = v_pay_amount,
          payment_status = public._derive_payment_status(v_pay_amount, v_pay_invoice_total)
      where id = v_pay_invoice_id;
    v_amount_paid_remaining := v_amount_paid_remaining - v_pay_amount;
  end loop;

  if v_discount_percent > v_settings.discount_tech_max and v_primary_invoice_id is not null then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_primary_invoice_id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if p_quotation_id is not null then
    update public.quotations set status = 'converted' where id = p_quotation_id and org_id = p_org_id;

    if v_lead_id is not null then
      update public.leads set status = 'won', updated_at = now() where id = v_lead_id and org_id = p_org_id;
    end if;
  end if;

  return jsonb_build_object(
    'spare_invoice_id', v_spare_invoice.id,
    'product_invoice_id', v_product_invoice.id,
    'amc_invoice_id', v_amc_invoice.id,
    'warranty_ids', to_jsonb(v_warranty_ids),
    'ticket_ids', to_jsonb(v_ticket_ids),
    'approval_id', v_approval_id,
    'redeemed_points', v_redeem_points,
    'redeemed_amount', v_redeem_amount
  );
end;
$function$;

-- register_product_via_qr
create or replace function public.register_product_via_qr(p_org_id uuid, p_product_id uuid, p_serial_no text, p_purchase_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_product products;
  v_warranty_id uuid;
  v_warranty warranties;
  v_address_id uuid;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'register_product_via_qr: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'register_product_via_qr: org mismatch';
  end if;

  select * into v_product from public.products where id = p_product_id and org_id = p_org_id;
  if v_product.id is null then
    raise exception 'register_product_via_qr: product % not found', p_product_id;
  end if;

  if p_serial_no is not null and btrim(p_serial_no) <> '' and exists (
    select 1 from public.warranties where org_id = p_org_id and serial_no = p_serial_no
  ) then
    raise exception 'register_product_via_qr: serial number % is already registered', p_serial_no;
  end if;

  insert into public.warranties (org_id, customer_id, product_id, serial_no, start_date, expiry_date)
  values (
    p_org_id, v_customer_id, p_product_id, nullif(btrim(p_serial_no), ''),
    coalesce(p_purchase_date, (now() at time zone 'Asia/Kolkata')::date),
    coalesce(p_purchase_date, (now() at time zone 'Asia/Kolkata')::date) + make_interval(months => v_product.warranty_months)
  )
  returning id into v_warranty_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'product_registered', 'Product registered via QR', v_product.name, v_warranty_id);

  select * into v_warranty from public.warranties where id = v_warranty_id;
  select a.id into v_address_id from public.addresses a
  where a.customer_id = v_customer_id and a.is_primary = true limit 1;

  v_total_visits := floor(
    (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
      + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
  )::integer;

  v_visit_date := v_warranty.start_date;
  for i in 1..v_total_visits loop
    v_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
    exit when v_visit_date > v_warranty.expiry_date;
    v_visit_date := public._visit_working_day(p_org_id, v_visit_date);

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, warranty_id
    ) values (
      p_org_id, v_customer_id, v_address_id, p_product_id,
      format('Warranty scheduled service %s of %s', i, v_total_visits), 'Warranty scheduled service',
      'warranty', 'normal', 'open', 'customer_app', v_warranty_id
    )
    returning id into v_ticket_id;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    perform public._auto_assign_ticket_internal(v_ticket_id, p_org_id, p_skip_rating_logic => true);

    if i = 1 then
      update public.warranties set next_service_date = v_visit_date where id = v_warranty_id;
    end if;
  end loop;

  return v_warranty_id;
end;
$function$;

-- refresh_amc_statuses
create or replace function public.refresh_amc_statuses(p_org_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_window integer;
begin
  if not public.is_ops_staff() then
    raise exception 'refresh_amc_statuses: only master or operation_admin may run this';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'refresh_amc_statuses: org mismatch';
  end if;

  select amc_book_window_days into v_window from public.settings where org_id = p_org_id;
  v_window := coalesce(v_window, 15);

  update public.amc_contracts
  set status = (case
    when expiry_date < (now() at time zone 'Asia/Kolkata')::date then 'expired'
    when expiry_date <= (now() at time zone 'Asia/Kolkata')::date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end)::amc_status
  where org_id = p_org_id and cancelled_at is null and status is distinct from (case
    when expiry_date < (now() at time zone 'Asia/Kolkata')::date then 'expired'
    when expiry_date <= (now() at time zone 'Asia/Kolkata')::date + (v_window || ' days')::interval then 'due_soon'
    else 'active'
  end)::amc_status;
end;
$function$;

-- report_coverage
create or replace function public.report_coverage(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_all_months integer;
  v_first date;     -- first kept month (1st of month)
  v_months integer;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_coverage: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  -- month count of the plain-date range, newest 36 kept
  v_all_months := greatest(0, (extract(year from p_to)::int - extract(year from p_from)::int) * 12
                              + extract(month from p_to)::int - extract(month from p_from)::int + 1);
  v_months := least(v_all_months, 36);
  v_first := (date_trunc('month', p_to::timestamp) - make_interval(months => greatest(v_months - 1, 0)))::date;

  with m as (
    select ms::date as ms, (ms + interval '1 month' - interval '1 day')::date as me
    from generate_series(v_first::timestamp, date_trunc('month', p_to::timestamp), interval '1 month') ms
    where v_months > 0
  ),
  months as (
    select m.ms, m.me, to_char(m.ms, 'YYYY-MM') as month,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'warranty'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as w_visits,
      (select count(*) from public.warranties w where w.org_id = v_org and w.start_date <= m.me and w.expiry_date >= m.ms) as w_active,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'amc'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as a_visits,
      (select count(*) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.cancelled_at is null and c.start_date <= m.me and c.expiry_date >= m.ms) as a_active,
      (select coalesce(sum(coalesce(p.price_per_year, p.price / greatest(p.years, 1)) / 12), 0) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.cancelled_at is null and c.start_date <= m.me and c.expiry_date >= m.ms) as a_value,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'rental'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as r_visits,
      (select count(*) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_active,
      (select coalesce(sum(p.monthly_rate), 0) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_value
    from m
  ),
  inst as (
    select il.technician_id, sum(il.qty)::bigint as qty
    from public.installations_logged il
    where il.org_id = v_org and il.created_at >= v_from and il.created_at < v_to
    group by il.technician_id
  ),
  vis as (
    select sv.technician_id, count(*) as cnt
    from public.service_visits sv
    where sv.org_id = v_org and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  agg as (
    select
      (select coalesce(sum(qty), 0) from inst) as installs,
      (select coalesce(sum(ii.qty), 0) from public.invoice_items ii
        where ii.org_id = v_org and ii.item_type = 'product' and ii.created_at >= v_from and ii.created_at < v_to) as units_sold,
      (select coalesce(sum(cnt), 0) from vis) as visits,
      (select count(*) from (select technician_id from inst union select technician_id from vis) x) as tech_count
  )
  select jsonb_build_object(
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', mo.month,
        'warranty', jsonb_build_object('visits', mo.w_visits, 'active', mo.w_active),
        'amc', jsonb_build_object('visits', mo.a_visits, 'active', mo.a_active, 'plan_value', round(mo.a_value, 2)),
        'rental', jsonb_build_object('visits', mo.r_visits, 'active', mo.r_active, 'plan_value', round(mo.r_value, 2))
      ) order by mo.ms) from months mo), '[]'::jsonb),
    'truncated', v_all_months > 36,
    'installation', jsonb_build_object(
      'installs', a.installs,
      'months_count', greatest(1, v_months),
      'technician_count', a.tech_count,
      'per_technician_per_month', case when a.tech_count > 0 then round(a.installs::numeric / a.tech_count / greatest(1, v_months), 2) end,
      'units_sold', a.units_sold,
      'per_product_sold', case when a.units_sold > 0 then round(a.installs::numeric / a.units_sold, 2) end,
      'visits', a.visits,
      'per_visit', case when a.visits > 0 then round(a.installs::numeric / a.visits, 2) end,
      'by_technician', coalesce((
        select jsonb_agg(jsonb_build_object('technician_id', i.technician_id, 'name', coalesce(p.full_name, '—'), 'installs', i.qty,
                                            'per_month', round(i.qty::numeric / greatest(1, v_months), 2))
                         order by i.qty desc, coalesce(p.full_name, '—'), i.technician_id)
        from inst i
        left join public.technicians t on t.id = i.technician_id
        left join public.profiles p on p.id = t.profile_id
      ), '[]'::jsonb)
    )
  ) into v_result
  from agg a;
  return v_result;
end;
$function$;

notify pgrst, 'reload schema';
