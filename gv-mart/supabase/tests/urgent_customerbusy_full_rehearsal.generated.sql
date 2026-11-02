-- GENERATED -- do not hand-edit.
do $outer$
declare
  v_t1 jsonb; v_t2 jsonb; v_t3 jsonb; v_t4 jsonb; v_t5 jsonb; v_t6 jsonb; v_t7 jsonb; v_t8 jsonb; v_t9 jsonb;
  v_appt1 appointments; v_appt2 appointments; v_appt3 appointments; v_appt4 appointments; v_appt5 appointments; v_appt6 appointments; v_appt7 appointments; v_appt8 appointments; v_appt9 appointments;
  v_r1 jsonb; v_r2 jsonb; v_r3 jsonb; v_r3_force jsonb; v_r4 jsonb; v_r5 jsonb; v_r5b jsonb; v_r6 jsonb; v_r6_force jsonb;
begin
  perform set_config('lock_timeout', '2000', true);
  perform set_config('request.jwt.claim.sub', '1e2238ed-a57f-4874-9664-3cc38106eeb9', true);

  execute $migration_ddl$
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

  $migration_ddl$;

  -- clear any pre-existing open appointments on the test customer
  update appointments a set status = 'cancelled'
  from service_tickets st
  where a.ticket_id = st.id and st.customer_id = 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid and a.status in ('scheduled', 'in_progress');

  -- Anchor appointment: 2026-11-10, 13:00-13:45 IST (07:30-08:15 UTC), assigned to Aakash.
  v_t1 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST anchor', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-10'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt1 from appointments where id = (v_t1->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-10 07:30:00+00'::timestamptz, ends_at = '2026-11-10 08:15:00+00'::timestamptz where id = v_appt1.id;
  perform public.assign_ticket_technician(v_appt1.id, '48a3dc54-6af7-439a-aaa4-2e6b906c7fcf'::uuid, false);

  -- Case 1: OTHER DAY (2026-11-20, no overlap by date) -- must be ALLOWED.
  v_t2 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case1 other day', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-20'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt2 from appointments where id = (v_t2->>'appointment_id')::uuid;
  v_r1 := public.assign_ticket_technician(v_appt2.id, 'cee294f0-9d45-4972-bf39-f2bb07f70f0a'::uuid, false);

  -- Case 2: SAME DAY, NON-OVERLAPPING (2026-11-10, 14:00-14:45 -- after anchor ends at 13:45) -- ALLOWED.
  v_t3 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case2 same day non-overlap', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-10'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt3 from appointments where id = (v_t3->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-10 08:30:00+00'::timestamptz, ends_at = '2026-11-10 09:15:00+00'::timestamptz where id = v_appt3.id;
  v_r2 := public.assign_ticket_technician(v_appt3.id, 'cee294f0-9d45-4972-bf39-f2bb07f70f0a'::uuid, false);

  -- Case 3: SAME DAY, OVERLAPPING (2026-11-10, 13:30-14:15 -- overlaps anchor's 13:00-13:45) -- BLOCKED, then FORCE allowed.
  v_t4 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case3 overlap', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-10'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt4 from appointments where id = (v_t4->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-10 08:00:00+00'::timestamptz, ends_at = '2026-11-10 08:45:00+00'::timestamptz where id = v_appt4.id;
  v_r3 := public.assign_ticket_technician(v_appt4.id, 'cee294f0-9d45-4972-bf39-f2bb07f70f0a'::uuid, false);
  v_r3_force := public.assign_ticket_technician(v_appt4.id, 'cee294f0-9d45-4972-bf39-f2bb07f70f0a'::uuid, true);

  -- Case 4: 13:20 BOUNDARY -- job ending exactly 13:20 (07:50 UTC) vs a new
  -- appointment starting exactly 13:20 -- end-exclusive, must be ALLOWED
  -- (no overlap at a shared boundary instant).
  v_t5 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case4a boundary-ends-1320', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-12'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt5 from appointments where id = (v_t5->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-12 06:35:00+00'::timestamptz, ends_at = '2026-11-12 07:50:00+00'::timestamptz where id = v_appt5.id;
  perform public.assign_ticket_technician(v_appt5.id, '48a3dc54-6af7-439a-aaa4-2e6b906c7fcf'::uuid, false);

  v_t6 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case4b boundary-starts-1320', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-12'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt6 from appointments where id = (v_t6->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-12 07:50:00+00'::timestamptz, ends_at = '2026-11-12 08:35:00+00'::timestamptz where id = v_appt6.id;
  v_r4 := public.assign_ticket_technician(v_appt6.id, 'cee294f0-9d45-4972-bf39-f2bb07f70f0a'::uuid, false);

  -- Case 5: TECHNICIAN check unchanged -- same technician, overlapping
  -- time, DIFFERENT customer -- must still be BLOCKED (technicianBusy),
  -- proving the technician-conflict path is untouched by this migration.
  v_t7 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case5 tech-still-blocked', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-15'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt7 from appointments where id = (v_t7->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-15 07:30:00+00'::timestamptz, ends_at = '2026-11-15 08:15:00+00'::timestamptz where id = v_appt7.id;
  perform public.assign_ticket_technician(v_appt7.id, '48a3dc54-6af7-439a-aaa4-2e6b906c7fcf'::uuid, false);
  -- second ticket, same technician Aakash, overlapping time, same customer too (irrelevant -- testing tech path)
  v_t8 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case5b tech-overlap', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-15'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt8 from appointments where id = (v_t8->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-15 08:00:00+00'::timestamptz, ends_at = '2026-11-15 08:45:00+00'::timestamptz where id = v_appt8.id;
  v_r5b := public.assign_ticket_technician(v_appt8.id, '48a3dc54-6af7-439a-aaa4-2e6b906c7fcf'::uuid, false);
  v_r5 := v_r5b;

  -- Case 3b: CLEAN customer-only overlap -- a DIFFERENT technician
  -- (Subash, no other appointments anywhere in this rehearsal) at a time
  -- that overlaps ONLY the anchor (same customer), isolating the
  -- customerBusy check from any technician-conflict interference. Must be
  -- BLOCKED with reason_key=customerBusy, then force must succeed.
  v_t9 := public._create_complaint_ticket_internal(
    'b6822905-5557-4e43-a606-f26ecfd5a541'::uuid, 'a71a2965-633e-41ae-aa46-f31e9db5a4cc'::uuid, 'f48a7801-bf2e-4b7e-af00-d9ab1bd0a4a8'::uuid, null, null, null,
    'ZZ TEST case3b clean customer overlap', null, 'normal'::priority_level, 'call'::ticket_channel, 'datetime'::appointment_mode, false,
    p_scheduled_date := '2026-11-10'::date, p_unlisted_product_name := 'ZZ TEST PRODUCT', p_unavailable_windows := '[]'::jsonb
  );
  select * into v_appt9 from appointments where id = (v_t9->>'appointment_id')::uuid;
  update appointments set scheduled_at = '2026-11-10 07:45:00+00'::timestamptz, ends_at = '2026-11-10 08:00:00+00'::timestamptz where id = v_appt9.id;
  v_r6 := public.assign_ticket_technician(v_appt9.id, '9c15bf18-d47a-45ef-9eac-a6f68ff2c0dc'::uuid, false);
  v_r6_force := public.assign_ticket_technician(v_appt9.id, '9c15bf18-d47a-45ef-9eac-a6f68ff2c0dc'::uuid, true);

  raise exception 'RESULTS: case1_other_day=% case2_same_day_nonoverlap=% case3_techbusy_blocked=% case3_techbusy_forced=% case3b_customerbusy_clean=% case3b_customerbusy_forced=% case4a_boundary_1320=% case5_tech_still_blocked=%',
    v_r1, v_r2, v_r3, v_r3_force, v_r6, v_r6_force, v_r4, v_r5;
end $outer$;
