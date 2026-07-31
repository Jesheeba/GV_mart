-- Task 5 (Customer Dashboard enhancement spec, 2026-07-30/31) — the
-- exception path layered on top of the unchanged, live auto-assignment
-- engine (_auto_assign_ticket_internal is NOT touched by this migration).
-- Locked design: when a customer follows up/complains repeatedly, or the
-- assigned technician can't make a scheduled day, an admin calls the
-- customer, logs their exact confirmed availability, and that logged
-- window must be visible to the assigned technician.
--
-- Reuses the existing appointments.scheduled_at/available_from/
-- available_to/rescheduled_from_date columns (Build Order STEP 4 /
-- assignment spec Phase 1/4 — see 20260723100000_step4_booking_model_
-- schema.sql) rather than inventing parallel scheduling state: those
-- columns already drive Phase 4's route ordering (isWindowOpenAt in
-- technician.ts), so writing a confirmed window into them is enough for
-- the engine/route logic to respect it with zero changes there. This
-- table is purely the audit/visibility log of WHY those columns changed
-- and what the admin was actually told on the call — the technician-
-- facing piece the raw time columns alone can't provide.

create table if not exists public.appointment_availability_calls (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  logged_by uuid not null references public.profiles(id),
  reason text not null check (reason in ('customer_followup', 'technician_unavailable')),
  confirmed_date date not null,
  confirmed_from time not null,
  confirmed_to time not null,
  note text,
  created_at timestamptz not null default now(),
  check (confirmed_from < confirmed_to)
);

create index if not exists appointment_availability_calls_appointment_idx
  on public.appointment_availability_calls (appointment_id, created_at desc);

alter table public.appointment_availability_calls enable row level security;

create policy appointment_availability_calls_staff_all on public.appointment_availability_calls
  for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- Same shape as appointment_unavailable_windows'/customer_exemption_windows'
-- assigned-technician policy: the technician currently holding this
-- appointment needs to read why their visit's window changed.
create policy appointment_availability_calls_select_assigned_technician on public.appointment_availability_calls
  for select
  using (exists (
    select 1 from public.appointments a
    where a.id = appointment_availability_calls.appointment_id
      and a.technician_id = public.current_technician_id()
  ));

grant select, insert on public.appointment_availability_calls to authenticated;

-- ── log_confirmed_availability ──────────────────────────────────────────
-- Writes the audit row AND folds the confirmed window into the appointment
-- itself (scheduled_at/available_from/available_to), stamping
-- rescheduled_from_date only when the date actually moved — same field
-- the existing customer-self-reschedule path uses, so TicketDetailPage's
-- "(rescheduled from X)" badge and Phase 4's route ordering both pick this
-- up automatically with no further wiring.
create or replace function public.log_confirmed_availability(
  p_appointment_id uuid,
  p_reason text,
  p_confirmed_date date,
  p_confirmed_from time,
  p_confirmed_to time,
  p_note text default null
)
returns public.appointment_availability_calls
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_prev_date date;
  v_row public.appointment_availability_calls;
begin
  if not public.is_ops_staff() then
    raise exception 'log_confirmed_availability: only ops staff may log a confirmed-availability call';
  end if;
  if p_reason not in ('customer_followup', 'technician_unavailable') then
    raise exception 'log_confirmed_availability: invalid reason %', p_reason;
  end if;
  if p_confirmed_from >= p_confirmed_to then
    raise exception 'log_confirmed_availability: confirmed_from must be before confirmed_to';
  end if;

  select org_id, scheduled_at::date into v_org_id, v_prev_date
  from public.appointments where id = p_appointment_id;
  if v_org_id is null then
    raise exception 'log_confirmed_availability: appointment % not found', p_appointment_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'log_confirmed_availability: org mismatch';
  end if;

  insert into public.appointment_availability_calls
    (org_id, appointment_id, logged_by, reason, confirmed_date, confirmed_from, confirmed_to, note)
  values
    (v_org_id, p_appointment_id, auth.uid(), p_reason, p_confirmed_date, p_confirmed_from, p_confirmed_to,
     nullif(btrim(coalesce(p_note, '')), ''))
  returning * into v_row;

  update public.appointments
  set scheduled_at = p_confirmed_date + p_confirmed_from,
      available_from = p_confirmed_from,
      available_to = p_confirmed_to,
      rescheduled_from_date = case when v_prev_date is distinct from p_confirmed_date then v_prev_date else rescheduled_from_date end
  where id = p_appointment_id;

  return v_row;
end;
$$;

grant execute on function public.log_confirmed_availability(uuid, text, date, time, time, text) to authenticated;
