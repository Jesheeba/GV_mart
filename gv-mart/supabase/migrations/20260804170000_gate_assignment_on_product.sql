-- Feature: a service ticket must have a defined product (a real catalog
-- product_id, OR a free-text unlisted_product_name typed by an admin when
-- the customer's actual product isn't in Masters yet) before a technician
-- can be assigned to it, auto or manual. Previously book_service_ticket
-- called the auto-assign engine unconditionally even when product_id was
-- null (the customer's "I don't know" escape hatch), so a product-less
-- ticket could still get handed to a technician with no idea what they're
-- fixing.
--
-- unlisted_product_name exists because requiring a real catalog product_id
-- would strand admins whenever the customer's product genuinely isn't in
-- Masters yet — "product defined" is therefore product_id IS NOT NULL OR
-- unlisted_product_name IS NOT NULL, not just the former.

alter table public.service_tickets add column if not exists unlisted_product_name text;

-- ── Assignment gates ─────────────────────────────────────────────────────
-- Bodies are otherwise verbatim from the currently-live versions in
-- 20260804130000_clear_followup_flag_on_assignment.sql — only the new
-- product-defined guard/clause is added to each.

create or replace function public._auto_assign_ticket_internal(
  p_ticket_id uuid,
  p_org_id uuid,
  p_skip_rating_logic boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
begin
  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % not found', p_ticket_id;
  end if;

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
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
      for update of t skip locked;
    elsif v_prior_stars is not null and v_prior_stars <= 3 then
      select t.id into v_tech_id
      from public.technicians t
      where t.org_id = p_org_id and t.is_active = true
        and exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
        and not exists (select 1 from public.appointments a where a.technician_id = t.id and a.status in ('scheduled','in_progress'))
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
        (v_appointment.scheduled_at is not null and v_appointment.scheduled_at::date > current_date)
        or exists (
          select 1 from public.attendance a
          where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
            and a.check_in_at is not null and a.check_out_at is null
        )
      )
      and (
        v_appointment.scheduled_at is null
        or v_appointment.scheduled_at::date <= current_date
        or not exists (
          select 1 from public.technician_availability ta
          where ta.technician_id = t.id
            and ta.date = v_appointment.scheduled_at::date
            and ta.status = 'leave'
        )
      )
      and not exists (
        select 1 from public.appointments a
        where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
      )
      and coalesce((
        select sum(st2.estimated_duration_minutes)
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = t.id
          and a2.status in ('scheduled', 'in_progress')
          and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ), 0) + coalesce(v_ticket.estimated_duration_minutes, 0) <= t.daily_capacity_minutes
    order by
      case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
        then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
        else null
      end asc nulls last,
      (
        select count(*) from public.appointments a2
        where a2.technician_id = t.id and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
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
        where a.technician_id = t.id and a.org_id = p_org_id and a.date = current_date
          and a.check_in_at is not null and a.check_out_at is null
      );
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
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
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = p_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$$;

create or replace function public._auto_assign_next_ticket_to_technician(
  p_org_id uuid,
  p_technician_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech technicians;
  v_appointment_id uuid;
  v_ticket_id uuid;
  v_ticket service_tickets;
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_tech from public.technicians where id = p_technician_id and org_id = p_org_id;
  if v_tech.id is null or not v_tech.is_active then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.technicianInactive');
  end if;

  if exists (
    select 1 from public.appointments a
    where a.technician_id = p_technician_id and a.status in ('scheduled', 'in_progress')
  ) then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyBusy');
  end if;

  if not exists (
    select 1 from public.attendance a
    where a.technician_id = p_technician_id and a.org_id = p_org_id and a.date = current_date
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
    and (a.scheduled_at is null or a.scheduled_at::date <= current_date)
    and coalesce((
      select sum(st2.estimated_duration_minutes)
      from public.appointments a2
      join public.service_tickets st2 on st2.id = a2.ticket_id
      where a2.technician_id = p_technician_id
        and a2.status in ('scheduled', 'in_progress')
        and a2.scheduled_at::date = coalesce(a.scheduled_at::date, current_date)
    ), 0) + coalesce(st.estimated_duration_minutes, 0) <= v_tech.daily_capacity_minutes
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
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', v_ticket_id), v_appointment_id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = p_technician_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id, 'appointment_id', v_appointment_id, 'ticket_id', v_ticket_id);
end;
$$;

create or replace function public.assign_ticket_technician(
  p_appointment_id uuid,
  p_technician_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
        public._customer_exemption_blocks(v_org_id, v_ticket.customer_id, v_appointment.scheduled_at::date)
      ) as blk
      where (blk ->> 'start')::time < v_appointment.available_to
        and (blk ->> 'end')::time > v_appointment.available_from
    ) then
      return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.exemptionWindowConflict');
    end if;
  end if;

  select a.id into v_conflict_appt_id
  from public.appointments a
  where a.technician_id = p_technician_id
    and a.status in ('scheduled', 'in_progress')
    and a.id <> p_appointment_id;

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
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = v_appointment.ticket_id;

  return jsonb_build_object('assigned', true, 'technician_id', p_technician_id);
end;
$$;

-- Intentionally NOT re-granted on any of the three — same reasoning as prior
-- migrations touching these functions: unchanged signatures, create-or-
-- replace preserves existing grants.

-- ── create_complaint_ticket: accept an admin-typed unlisted product name ──
-- Verbatim body from the currently-live version
-- (20260804150000_referral_capture_functions.sql, which added
-- p_referred_by_technician_id + FINDER CREDIT lead capture) plus one more
-- new trailing default param — same compatible-signature-change pattern
-- this function has already gone through twice.

create or replace function public.create_complaint_ticket(
  p_org_id uuid,
  p_customer_id uuid,
  p_address_id uuid,
  p_product_id uuid,
  p_brand_id uuid,
  p_model_id uuid,
  p_name_of_complaint text,
  p_nature_of_complaint text,
  p_priority priority_level,
  p_channel ticket_channel,
  p_appointment_mode appointment_mode,
  p_auto_assign boolean,
  p_scheduled_date date default null,
  p_slot_id uuid default null,
  p_referred_by_technician_id uuid default null,
  p_unlisted_product_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_settings settings;
  v_detected jsonb;
  v_type ticket_type;
  v_sla_hours numeric;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_assign_result jsonb;
  v_slot appointment_slots;
  v_appointment_snapshot appointments;
  v_lead_id uuid; -- REFERRAL: resolved technician referral, if any
  v_customer_name text;
begin
  if not public.is_ops_staff() then
    raise exception 'create_complaint_ticket: only master or operation_admin may raise a ticket';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_complaint_ticket: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_complaint_ticket: customer % not found', p_customer_id;
  end if;
  if p_name_of_complaint is null or btrim(p_name_of_complaint) = '' then
    raise exception 'create_complaint_ticket: name_of_complaint is required';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_complaint_ticket: no settings row for org %', p_org_id;
  end if;

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Service customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Service ticket, referred by technician');
  end if;

  v_detected := public._detect_ticket_type(p_org_id, p_customer_id, p_product_id);
  v_type := (v_detected ->> 'type')::ticket_type;

  v_sla_hours := case p_priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;

  insert into public.service_tickets (
    org_id, customer_id, address_id, product_id, brand_id, model_id, unlisted_product_name,
    name_of_complaint, nature_of_complaint, type, priority, status, channel, sla_due_at, lead_id
  ) values (
    p_org_id, p_customer_id, p_address_id, p_product_id, p_brand_id, p_model_id, nullif(btrim(coalesce(p_unlisted_product_name, '')), ''),
    p_name_of_complaint, nullif(btrim(coalesce(p_nature_of_complaint, '')), ''), v_type, p_priority, 'open', p_channel,
    now() + v_sla_hours * interval '1 hour', v_lead_id
  )
  returning id into v_ticket_id;

  if p_appointment_mode = 'datetime' then
    if p_scheduled_date is null or p_slot_id is null then
      raise exception 'create_complaint_ticket: scheduled date and slot are required for a datetime appointment';
    end if;

    if p_scheduled_date < (now() at time zone 'Asia/Kolkata')::date then
      raise exception 'create_complaint_ticket: scheduled date cannot be in the past';
    end if;

    select * into v_slot from public.appointment_slots where id = p_slot_id and org_id = p_org_id and is_active = true;
    if v_slot.id is null then
      raise exception 'create_complaint_ticket: slot % not found or inactive', p_slot_id;
    end if;

    if p_scheduled_date = (now() at time zone 'Asia/Kolkata')::date
       and v_slot.end_time <= (now() at time zone 'Asia/Kolkata')::time then
      raise exception 'create_complaint_ticket: slot % has already ended for today', p_slot_id;
    end if;

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, slot_id, status)
    values (p_org_id, v_ticket_id, 'datetime', (p_scheduled_date + v_slot.start_time) at time zone 'Asia/Kolkata', p_slot_id, 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public._auto_assign_ticket_internal(v_ticket_id, p_org_id);
    end if;
  elsif p_appointment_mode = 'always' then
    insert into public.appointments (org_id, ticket_id, mode, status)
    values (p_org_id, v_ticket_id, 'always', 'scheduled')
    returning id into v_appointment_id;

    if p_auto_assign then
      v_assign_result := public.auto_assign_ticket(v_ticket_id);
    end if;
  end if;

  if v_appointment_id is not null then
    select * into v_appointment_snapshot from public.appointments where id = v_appointment_id;
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'appointment_id', v_appointment_id,
    'detected_type', v_detected,
    'assign_result', v_assign_result,
    'scheduled_at', v_appointment_snapshot.scheduled_at,
    'slot_id', v_appointment_snapshot.slot_id,
    'slot_name', v_slot.name,
    'slot_start_time', v_slot.start_time,
    'slot_end_time', v_slot.end_time
  );
end;
$$;

grant execute on function public.create_complaint_ticket(
  uuid, uuid, uuid, uuid, uuid, uuid, text, text, priority_level, ticket_channel, appointment_mode, boolean, date, uuid, uuid, text
) to authenticated;

-- ── Optional customer photo attachment on "I don't know the product" ─────
-- Private bucket (not public-read like product-photos/product-documents):
-- this is customer-submitted evidence tied to one ticket, not marketing
-- collateral, so access is scoped to the uploading customer + ops staff
-- rather than bucket-wide public read.

create table public.service_ticket_photos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  ticket_id uuid not null references public.service_tickets(id) on delete cascade,
  storage_path text not null,
  created_at timestamptz not null default now()
);

alter table public.service_ticket_photos enable row level security;

create policy service_ticket_photos_insert on public.service_ticket_photos for insert to authenticated with check (
  org_id = public.current_org_id() and (
    public.is_ops_staff()
    or exists (select 1 from public.service_tickets st where st.id = ticket_id and st.customer_id = public.current_customer_id())
  )
);

create policy service_ticket_photos_select on public.service_ticket_photos for select to authenticated using (
  org_id = public.current_org_id() and public.is_ops_staff()
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ticket-photos', 'ticket-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy ticket_photos_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'ticket-photos' and (public.is_ops_staff() or public.current_customer_id() is not null)
);
create policy ticket_photos_select on storage.objects for select to authenticated using (
  bucket_id = 'ticket-photos' and public.is_ops_staff()
);
create policy ticket_photos_delete on storage.objects for delete to authenticated using (
  bucket_id = 'ticket-photos' and public.is_ops_staff()
);
