-- APPLY script for 20261204110000_time_aware_customer_busy_check.sql
--
-- Guard 1: refuse if this version is already registered.
-- Guard 2: refuse if the live assign_ticket_technician has drifted from the
--          pin this migration was reviewed against (sha256 CR-tolerant).
-- Then: apply the DDL, snapshot anon-exposure before/after inline (so the
-- diff is part of the same transaction as the real change, not a separate
-- best-effort check), register the version, and return a confirmation
-- including the anon diff for independent eyeballing.

do $guard$
declare
  v_live_sha text;
begin
  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261204110000') then
    raise exception 'already registered: migration 20261204110000 has already been applied -- refusing to re-apply';
  end if;

  select encode(sha256(regexp_replace(pg_get_functiondef(p.oid), E'\\r\\n', E'\n', 'g')::bytea), 'hex') into v_live_sha
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'assign_ticket_technician';

  if v_live_sha is distinct from '469dae2fc0211555056c720bfe9af164687f048d6c1ab27dd9ef63c670cf63be' then
    raise exception 'DRIFT DETECTED: live assign_ticket_technician no longer matches the reviewed pin (live=%) -- refusing to apply, re-pin and re-review before retrying', v_live_sha;
  end if;
end $guard$;

do $anon_before$
begin
  create temp table if not exists zz_anon_exposure_before (fn text) on commit drop;
  insert into zz_anon_exposure_before
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');
end $anon_before$;

-- ── 1. _customer_conflict_appt helper ───────────────────────────────────────
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

-- ── 2. assign_ticket_technician (customer-conflict block replaced) ─────────
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

revoke all on function public.assign_ticket_technician(uuid, uuid, boolean) from public, anon;
grant execute on function public.assign_ticket_technician(uuid, uuid, boolean) to authenticated, service_role;

-- ── register + anon-exposure diff + confirmation ────────────────────────
insert into supabase_migrations.schema_migrations (version, name, statements)
values ('20261204110000', 'time_aware_customer_busy_check', array[]::text[]);

do $anon_after$
declare
  v_new_grants text[];
begin
  create temp table if not exists zz_anon_exposure_after (fn text) on commit drop;
  insert into zz_anon_exposure_after
  select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');

  select array_agg(fn) into v_new_grants
  from zz_anon_exposure_after
  where fn not in (select fn from zz_anon_exposure_before);

  if v_new_grants is not null then
    raise exception 'ANON EXPOSURE REGRESSION: new anon-executable functions after this migration: %', v_new_grants;
  end if;
end $anon_after$;

select
  'applied' as status,
  now() as applied_at,
  (select count(*) from zz_anon_exposure_before) as anon_before_count,
  (select count(*) from zz_anon_exposure_after) as anon_after_count,
  (select pg_get_function_arguments(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='assign_ticket_technician') as assign_args,
  (select encode(sha256(regexp_replace(pg_get_functiondef(p.oid), E'\\r\\n', E'\n', 'g')::bytea), 'hex')
   from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='_customer_conflict_appt') as new_helper_sha;
