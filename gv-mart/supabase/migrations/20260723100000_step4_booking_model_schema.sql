-- STEP 4 of GV_Mart_Build_Order_and_Guardrails.md (Meeting spec Section B):
-- the owner's headline booking model. Schema + pure helper functions only —
-- no RPC behaviour change in this migration (that's
-- 20260723101000_step4_booking_rpcs.sql). Does NOT touch
-- public._auto_assign_ticket_internal (STEP 3 owns that function this
-- round, per the Build Order's hard constraint) — B1-B4 are built entirely
-- as new data + orchestration around the existing, unmodified engine.
--
-- B1 (date-only + unavailable windows): appointments.available_from/to
-- already exist (20260721091000) but only ever carry a single caller-typed
-- range. The customer instead marks MULTIPLE not-available windows across a
-- chosen date — appointment_unavailable_windows stores the raw marks (also
-- shown red in the UI, per spec), and _largest_free_window (below) derives
-- the single largest remaining contiguous window from
-- settings.work_start/work_end minus those marks, which is what actually
-- gets written into appointments.available_from/available_to.
--
-- B2 (narrow-availability guard): appointments.is_narrow_window flags a
-- booking whose derived window is small (<= settings.narrow_window_
-- threshold_minutes, itself settings-driven per this spec's global
-- principle, not hardcoded) — the booking RPCs (next migration) additionally
-- refuse to book a narrow window that's physically shorter than the job's
-- own estimated_duration_minutes, forcing the next-day path instead of
-- silently overbooking a slot nothing can fit in.
--
-- B3 (today-full -> next-day-first-priority): appointments.next_day_priority
-- + rescheduled_from_date record that a booking got bumped a day because the
-- requested date had no assignable technician capacity (determined by
-- actually calling the existing, unmodified _auto_assign_ticket_internal and
-- reading its own noneAvailable result — the same daily_capacity_minutes vs
-- sum(estimated_duration_minutes) accounting Phase 2 already uses, reused
-- rather than re-implemented).
--
-- B4 (exemption windows) — SCOPE-GUARD, explicitly re-authorized by the
-- Build Order: customer_exemption_windows is a persistent, admin-managed,
-- per-customer set of short recurring "never assign a technician here"
-- windows (school run, medical), independent of any single booking.
-- _customer_exemption_blocks (below) reads the ones active for a given date
-- so the booking RPCs can fold them into the same "blocked" set B1's
-- unavailable-window marks use — exemption time is never offered as part of
-- the derived available window in the first place, which is how assignment
-- ends up excluded from it without ever touching the assignment engine.

-- ── B2: settings-driven narrow-window threshold ─────────────────────────
alter table public.settings
  add column if not exists narrow_window_threshold_minutes integer not null default 90
    check (narrow_window_threshold_minutes > 0);

-- ── B2/B3: appointment-level booking-model flags ────────────────────────
alter table public.appointments
  add column if not exists is_narrow_window boolean not null default false,
  add column if not exists next_day_priority boolean not null default false,
  add column if not exists rescheduled_from_date date;

-- ── B1: raw customer-marked unavailable windows for a booking (display +
-- audit; the DERIVED single window lives in appointments.available_from/to,
-- computed by _largest_free_window from these) ──────────────────────────
create table if not exists public.appointment_unavailable_windows (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  check (start_time < end_time)
);

create index if not exists appointment_unavailable_windows_appointment_idx
  on public.appointment_unavailable_windows (appointment_id);

alter table public.appointment_unavailable_windows enable row level security;

create policy appointment_unavailable_windows_staff_all on public.appointment_unavailable_windows
  for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy appointment_unavailable_windows_select_own_customer on public.appointment_unavailable_windows
  for select
  using (exists (
    select 1 from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    where a.id = appointment_unavailable_windows.appointment_id
      and st.customer_id = public.current_customer_id()
  ));

create policy appointment_unavailable_windows_select_assigned_technician on public.appointment_unavailable_windows
  for select
  using (exists (
    select 1 from public.appointments a
    where a.id = appointment_unavailable_windows.appointment_id
      and a.technician_id = public.current_technician_id()
  ));

grant select, insert, update, delete on public.appointment_unavailable_windows to authenticated;

-- ── B4: per-customer exemption windows (SCOPE-GUARD, authorized) ────────
-- day_of_week null = applies every day; 0-6 = Sunday-Saturday
-- (extract(dow from date), matched in _customer_exemption_blocks below).
create table if not exists public.customer_exemption_windows (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  label text not null,
  day_of_week smallint check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_time < end_time)
);

create index if not exists customer_exemption_windows_customer_idx
  on public.customer_exemption_windows (org_id, customer_id) where is_active;

alter table public.customer_exemption_windows enable row level security;

create policy customer_exemption_windows_staff_all on public.customer_exemption_windows
  for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy customer_exemption_windows_select_own on public.customer_exemption_windows
  for select
  using (customer_id = public.current_customer_id());

-- Lets a technician currently holding an open appointment for this customer
-- see why a window is red on their own job screen — read-only, no write path.
create policy customer_exemption_windows_select_assigned_technician on public.customer_exemption_windows
  for select
  using (exists (
    select 1 from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    where st.customer_id = customer_exemption_windows.customer_id
      and a.technician_id = public.current_technician_id()
      and a.status in ('scheduled', 'in_progress')
  ));

grant select, insert, update, delete on public.customer_exemption_windows to authenticated;

-- 20260701091200_functions_triggers.sql only wires public.set_updated_at()
-- onto tables that existed AT THAT TIME (a one-off DO-block scan of
-- information_schema, not an ongoing mechanism) — new tables must add their
-- own trigger explicitly, same as every other post-Phase-1 migration that
-- introduced an updated_at column (e.g. technician_availability did NOT get
-- one automatically either, and indeed has none; this table's is genuinely
-- mutated after creation via admin edits, so it needs one).
drop trigger if exists set_updated_at on public.customer_exemption_windows;
create trigger set_updated_at
  before update on public.customer_exemption_windows
  for each row execute function public.set_updated_at();

-- ── Pure helper: largest free window in [p_work_start, p_work_end] once
-- every window in p_blocked (jsonb array of {"start":"HH:MM","end":"HH:MM"})
-- is removed. Overlapping/out-of-range blocked windows are clipped/merged;
-- ties go to the earliest-starting gap. Returns
-- {"available_from","available_to","minutes"} with available_from/to null
-- and minutes 0 when the whole range is blocked. ───────────────────────
create or replace function public._largest_free_window(
  p_work_start time,
  p_work_end time,
  p_blocked jsonb
)
returns jsonb
language sql
stable
as $$
  with raw as (
    select
      greatest((elem->>'start')::time, p_work_start) as s,
      least((elem->>'end')::time, p_work_end) as e
    from jsonb_array_elements(coalesce(p_blocked, '[]'::jsonb)) as elem
  ),
  valid as (
    select s, e from raw where s < e
  ),
  -- Classic "merge overlapping intervals" via window functions: a row starts
  -- a new merged group whenever its start is past the running max end of
  -- every earlier row (sorted by start) — otherwise it's absorbed into the
  -- current group.
  with_prev_max as (
    select s, e,
      max(e) over (order by s rows between unbounded preceding and 1 preceding) as prev_max_e
    from valid
  ),
  grouped as (
    select s, e,
      sum(case when prev_max_e is null or s > prev_max_e then 1 else 0 end) over (order by s) as grp
    from with_prev_max
  ),
  merged as (
    select min(s) as s, max(e) as e from grouped group by grp
  ),
  gaps as (
    select lag(e, 1, p_work_start) over (order by s) as gap_start, s as gap_end from merged
    union all
    select coalesce((select max(e) from merged), p_work_start), p_work_end
  ),
  ranked as (
    select gap_start, gap_end, (extract(epoch from (gap_end - gap_start))::integer / 60) as minutes
    from gaps
    where gap_end > gap_start
    order by minutes desc, gap_start asc
    limit 1
  )
  select case when exists (select 1 from ranked)
    then jsonb_build_object(
      'available_from', (select gap_start from ranked),
      'available_to', (select gap_end from ranked),
      'minutes', (select minutes from ranked)
    )
    else jsonb_build_object('available_from', null, 'available_to', null, 'minutes', 0)
  end;
$$;

-- ── Pure(ish) helper: active exemption windows for a customer on a given
-- date, shaped identically to a customer's raw unavailable-window marks
-- ({"start","end"} strings) so callers can jsonb-concat the two straight
-- into _largest_free_window's p_blocked. ────────────────────────────────
create or replace function public._customer_exemption_blocks(
  p_org_id uuid,
  p_customer_id uuid,
  p_date date
)
returns jsonb
language sql
stable
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object('start', to_char(start_time, 'HH24:MI'), 'end', to_char(end_time, 'HH24:MI'))
      order by start_time
    ),
    '[]'::jsonb
  )
  from public.customer_exemption_windows
  where org_id = p_org_id
    and customer_id = p_customer_id
    and is_active = true
    and (day_of_week is null or day_of_week = extract(dow from p_date)::smallint);
$$;

grant execute on function public._largest_free_window(time, time, jsonb) to authenticated;
grant execute on function public._customer_exemption_blocks(uuid, uuid, date) to authenticated;
