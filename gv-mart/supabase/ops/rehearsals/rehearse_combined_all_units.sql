-- Combined rehearsal wrapper -- all six Monthly Expenses migrations
-- (20261107100000 through 20261107100500), applied in order, followed by
-- all nine of this feature's SQL tests, all inside ONE DO block.
--
-- Standard form: refuses before 18:00 IST; each migration's pinned sha256
-- is recomputed via convert_to(text,'UTF8') then digest(...,'sha256') (not
-- pgcrypto's text-argument overload) so the hash is taken over the exact
-- UTF-8 byte sequence, matching how sha256sum hashes the file on disk;
-- fingerprints the real organisation's salaries/incentives_earned rows
-- before anything runs; EXECUTEs each migration verbatim, in order; runs
-- each test (each test is itself a self-contained `do $t$ ... end $t$;`
-- block that always raises `RESULTS...` at its own end) inside a nested
-- BEGIN/EXCEPTION so its own RAISE is caught here instead of aborting the
-- whole wrapper -- PL/pgSQL has no bare SAVEPOINT, so this nested block is
-- the idiomatic substitute: entering it creates an implicit savepoint, and
-- catching the test's own terminal exception rolls back everything that
-- test did against the real organisation's data while keeping the
-- `sqlerrm` text (plpgsql variables are not part of the rolled-back state);
-- ends in ONE unconditional final RAISE so the six migrations, and every
-- test's already-caught-and-rolled-back side effect, are ALL undone
-- together when this whole statement finishes. Run through the Management
-- API (database/query), never psql. Read RESULTS in the error. No
-- BEGIN/COMMIT at the top level anywhere in this file: that would defeat
-- the rollback.
do $combo$
declare
  res text := '';
  v_now_ist timestamptz := now() at time zone 'Asia/Kolkata';
  v_org uuid;
  v_org_count int;
  v_fp_before text;
  v_fp_after text;
  v_actual_sha256 text;
  v_test_result text;
  v_m1 text := $m1body$
-- Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md), Unit 1 — bike
-- ownership and petrol rate per technician, effective-dated so a mid-month
-- switch is representable (§1.2/§3.1). Overlap is rejected by the database
-- via an EXCLUDE constraint (not just the UI) — btree_gist is new to this
-- codebase, introduced here specifically because no existing table needed
-- overlap-range enforcement before.
--
-- Effective-date convention: ranges are closed-inclusive on both ends
-- (effective_to is the last day the row applies, not the day of change).
-- A switch "on the 12th" means the OLD row's effective_to is the 11th and
-- the NEW row's effective_from is the 12th — adjacent, non-overlapping,
-- inclusive ranges.

create extension if not exists btree_gist;

create table public.technician_vehicles (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  ownership text not null check (ownership in ('own', 'company')),
  petrol_rate_per_km numeric(12, 2) not null default 0 check (petrol_rate_per_km >= 0),
  effective_from date not null,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    technician_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
);

create index technician_vehicles_org_id_idx on public.technician_vehicles (org_id);
create index technician_vehicles_technician_id_idx on public.technician_vehicles (technician_id, effective_from);

alter table public.technician_vehicles enable row level security;

-- Master + operation_admin only (spec §1.8) — no policy at all for
-- technician, which is a default-deny in Postgres RLS: a technician cannot
-- read or write this table through any path.
create policy technician_vehicles_select_ops on public.technician_vehicles
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy technician_vehicles_write_ops on public.technician_vehicles for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_technician_vehicles after insert or update or delete on public.technician_vehicles
  for each row execute function public.audit_master_change();

-- "Which bike was this technician on, on this date" — a null-id row (no
-- match) is the no-vehicle-row case; callers check `.id is null`.
create or replace function public.technician_vehicle_on(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date
)
returns public.technician_vehicles
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.technician_vehicles
  where org_id = p_org_id
    and technician_id = p_technician_id
    and effective_from <= p_date
    and coalesce(effective_to, 'infinity'::date) >= p_date
  limit 1;
$$;

-- "How many days of this calendar month were they on their own bike" — sums
-- the overlap, in days, between [month start, month end) and every 'own'
-- row's [effective_from, effective_to] (inclusive), handling a technician
-- with several own/company rows across the month. Feeds Unit 5's pro-rated
-- own-bike allowance.
create or replace function public.technician_own_bike_days(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_period)::date;
  v_end date := (date_trunc('month', p_period)::date + interval '1 month')::date; -- exclusive
  v_total integer := 0;
  v_row record;
  v_seg_start date;
  v_seg_end date; -- exclusive
begin
  for v_row in
    select effective_from, effective_to
    from public.technician_vehicles
    where org_id = p_org_id
      and technician_id = p_technician_id
      and ownership = 'own'
      and effective_from < v_end
      and coalesce(effective_to, 'infinity'::date) >= v_start
  loop
    v_seg_start := greatest(v_start, v_row.effective_from);
    v_seg_end := least(v_end, coalesce(v_row.effective_to + 1, 'infinity'::date));
    if v_seg_end > v_seg_start then
      v_total := v_total + (v_seg_end - v_seg_start);
    end if;
  end loop;
  return v_total;
end;
$$;

grant execute on function public.technician_vehicle_on(uuid, uuid, date) to authenticated;
grant execute on function public.technician_own_bike_days(uuid, uuid, date) to authenticated;
-- 20261024100000_close_public_and_anon_function_execute closed the default
-- (a function postgres creates is no longer born PUBLIC-executable), but
-- these are stated explicitly anyway rather than relying on migration
-- ordering alone.
revoke execute on function public.technician_vehicle_on(uuid, uuid, date) from public, anon;
revoke execute on function public.technician_own_bike_days(uuid, uuid, date) from public, anon;
$m1body$;
  v_m2 text := $m2body$
-- Monthly Expenses spec, Unit 2 — kilometre log (§1.5/§3.2). Append-only: no
-- update or delete policy exists for ANY role, including master — a
-- mistaken entry is corrected with a compensating entry, never edited in
-- place, so "no code path updates or deletes a row" is enforced by the
-- database itself, not by convention. `logged_by`/nullable-on-delete-set-null
-- matches this codebase's existing audit-column convention (see
-- 20260924120100_expense_tracking_columns.sql's `expenses.logged_by`),
-- renamed from the spec's proposed `entered_by`.

create table public.technician_km_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  entry_date date not null,
  km numeric(12, 2) not null check (km > 0),
  note text,
  logged_by uuid references public.profiles (id) on delete set null default auth.uid(),
  entered_at timestamptz not null default now()
);

create index technician_km_log_org_id_idx on public.technician_km_log (org_id);
create index technician_km_log_technician_id_idx on public.technician_km_log (technician_id, entry_date);

alter table public.technician_km_log enable row level security;

create policy technician_km_log_select_staff on public.technician_km_log
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy technician_km_log_select_own on public.technician_km_log
  for select using (technician_id = public.current_technician_id());
create policy technician_km_log_insert_own on public.technician_km_log
  for insert with check (technician_id = public.current_technician_id());
create policy technician_km_log_insert_staff on public.technician_km_log
  for insert with check (org_id = public.current_org_id() and public.is_ops_staff());
-- Deliberately no update/delete policy at all (for any role) — append-only.

-- Monthly sum of the manual log — informational total shown on the salary
-- breakdown and the verification queue (§1.5). Payment for petrol is the
-- admin's verified claim amount (Unit 3/6), not this figure.
create or replace function public.technician_km_log_sum(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(km), 0)
  from public.technician_km_log
  where org_id = p_org_id
    and technician_id = p_technician_id
    and entry_date >= date_trunc('month', p_period)::date
    and entry_date < (date_trunc('month', p_period)::date + interval '1 month');
$$;

grant execute on function public.technician_km_log_sum(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_km_log_sum(uuid, uuid, date) from public, anon;

-- Petrol REFERENCE figure — not the payment. Owner revision: the bill is for
-- validation, and once a claim is verified the admin's entered amount is
-- what is paid (Unit 3/6). This exists so the admin has something to check
-- that verified amount against. Priced per entry against whichever
-- technician_vehicles row was effective on THAT entry's own date (table
-- 20261107100000_technician_vehicles.sql), not month-total-km x the rate at
-- month end — a rate changed on the 10th must not re-price the first nine
-- days, the same day-level precision technician_own_bike_days already uses
-- for ownership.
create or replace function public.technician_petrol_reference_amount(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(l.km * coalesce(v.petrol_rate_per_km, 0)), 0)
  from public.technician_km_log l
  left join public.technician_vehicles v
    on v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and v.effective_from <= l.entry_date
    and coalesce(v.effective_to, 'infinity'::date) >= l.entry_date
  where l.org_id = p_org_id
    and l.technician_id = p_technician_id
    and l.entry_date >= date_trunc('month', p_period)::date
    and l.entry_date < (date_trunc('month', p_period)::date + interval '1 month');
$$;

grant execute on function public.technician_petrol_reference_amount(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_petrol_reference_amount(uuid, uuid, date) from public, anon;

-- Approximate distance for the same technician/month, from the GPS ping
-- trail (`technician_locations`) already recorded by live tracking —
-- reference only, displayed alongside the manual log for comparison. Never
-- replaces it and is not summed into any payable figure. Nothing in this
-- codebase pre-aggregated this before; it is computed here, on read, as a
-- straight sum of Haversine distances between consecutive pings in the
-- month (R = 6371 km) — noisy by nature (GPS drift, gaps when the app is
-- closed), which is exactly why the spec treats it as a reference, not a
-- source of payment.
create or replace function public.technician_approx_distance_km(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with pings as (
    select
      lat, lng,
      lag(lat) over (order by recorded_at) as prev_lat,
      lag(lng) over (order by recorded_at) as prev_lng
    from public.technician_locations
    where org_id = p_org_id
      and technician_id = p_technician_id
      and recorded_at >= date_trunc('month', p_period)
      and recorded_at < date_trunc('month', p_period) + interval '1 month'
  )
  select coalesce(round(sum(
    2 * 6371 * asin(least(1, sqrt(
      sin(radians(lat - prev_lat) / 2) ^ 2
      + cos(radians(prev_lat)) * cos(radians(lat)) * sin(radians(lng - prev_lng) / 2) ^ 2
    )))
  )::numeric, 1), 0)
  from pings
  where prev_lat is not null and prev_lng is not null;
$$;

grant execute on function public.technician_approx_distance_km(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_approx_distance_km(uuid, uuid, date) from public, anon;
$m2body$;
  v_m3 text := $m3body$
-- Monthly Expenses spec, Unit 3 — petrol/maintenance bill submission and
-- verification (§1.4/§3.3, and the owner's revision superseding §1.3 — the
-- bill is for validation, and once verified the admin's entered amount IS
-- the payment, for petrol exactly as for maintenance). `verified_amount is
-- null` is the gate: a row with no verified_amount is invisible to salary
-- and the report through any code path, because Units 5-7 only ever read
-- verified rows. There is no separate rejected state — verifying at zero
-- behaves as a rejection, the row and photo survive, `reason` records why.
-- Both claim_types share this exact mechanism; see Unit 6 for how the
-- kilometres x rate figure is kept as a reference the admin checks the bill
-- against, never as the payment formula.
--
-- Write path matches this codebase's `payment_proofs` convention
-- (20260807092000_payment_proofs.sql): no direct client insert/update grant
-- on the table at all — the technician's identity and the claim's shape are
-- resolved and validated entirely inside the two RPCs below, never trusted
-- from client-supplied columns.

create table public.expense_claims (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  technician_id uuid not null references public.technicians (id) on delete cascade,
  period date not null,
  claim_type text not null check (claim_type in ('petrol', 'maintenance')),
  submitted_amount numeric(12, 2) not null check (submitted_amount >= 0),
  bill_photo_path text not null,
  submitted_at timestamptz not null default now(),
  verified_amount numeric(12, 2) check (verified_amount >= 0),
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  reason text,
  -- The whole audit trail: a verified figure that differs from what was
  -- submitted must carry a written reason, enforced here so it can never be
  -- bypassed by skipping a frontend form.
  constraint expense_claims_reason_required_if_adjusted check (
    verified_amount is null or verified_amount = submitted_amount or reason is not null
  )
);

create index expense_claims_org_id_idx on public.expense_claims (org_id);
create index expense_claims_technician_id_idx on public.expense_claims (technician_id, period);
create index expense_claims_period_idx on public.expense_claims (org_id, period) where verified_amount is not null;

alter table public.expense_claims enable row level security;

create policy expense_claims_select_staff on public.expense_claims
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy expense_claims_select_own on public.expense_claims
  for select using (technician_id = public.current_technician_id());
-- No insert/update/delete policy on the table — every write goes through
-- submit_expense_claim / verify_expense_claim below.

create trigger audit_expense_claims after insert or update or delete on public.expense_claims
  for each row execute function public.audit_master_change();

-- ── Storage: private bucket, technician-scoped path ───────────────────────
-- Same 5MB/image-only limits as every other photo bucket in this codebase.
-- Path shape `${orgId}/${technicianId}/${uuid}.${ext}` lets the storage
-- policy scope access per-technician without a lookup table, same idea as
-- payment-proofs' `current_technician_id() is not null` but tightened one
-- level further so a technician can't even upload into another technician's
-- folder, let alone read one by guessing a key.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-claim-photos', 'expense-claim-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy expense_claim_photos_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'expense-claim-photos'
  and public.current_technician_id() is not null
  and (storage.foldername(name))[2] = public.current_technician_id()::text
);
create policy expense_claim_photos_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'expense-claim-photos'
  and (
    public.is_ops_staff()
    or (storage.foldername(name))[2] = public.current_technician_id()::text
  )
);
-- No delete policy on the bucket or the table: proofs are permanent, same
-- posture as payment-proofs/technician-documents.

-- ── submit_expense_claim: technician uploads, identity resolved server-side ─
create or replace function public.submit_expense_claim(
  p_org_id uuid,
  p_claim_type text,
  p_submitted_amount numeric,
  p_bill_photo_path text,
  p_period date default current_date
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_claim public.expense_claims;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'submit_expense_claim: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_expense_claim: org mismatch';
  end if;
  if p_claim_type not in ('petrol', 'maintenance') then
    raise exception 'submit_expense_claim: invalid claim_type %', p_claim_type;
  end if;
  if p_submitted_amount < 0 then
    raise exception 'submit_expense_claim: submitted_amount must be non-negative';
  end if;
  if nullif(btrim(p_bill_photo_path), '') is null then
    raise exception 'submit_expense_claim: bill_photo_path is required';
  end if;

  insert into public.expense_claims (org_id, technician_id, period, claim_type, submitted_amount, bill_photo_path)
  values (p_org_id, v_tech_id, date_trunc('month', p_period)::date, p_claim_type, p_submitted_amount, p_bill_photo_path)
  returning * into v_claim;

  return v_claim;
end;
$$;

grant execute on function public.submit_expense_claim(uuid, text, numeric, text, date) to authenticated;
revoke execute on function public.submit_expense_claim(uuid, text, numeric, text, date) from public, anon;

-- ── verify_expense_claim: master/operation_admin sets the figure that pays ──
-- `verified_amount = 0` with a reason IS the "rejected" state (§1.4) — no
-- separate status column, nothing is deleted. Re-running this on an
-- already-verified claim is allowed (an admin correcting their own earlier
-- verification), and still goes through the same reason-required check.
create or replace function public.verify_expense_claim(
  p_claim_id uuid,
  p_verified_amount numeric,
  p_reason text default null
)
returns public.expense_claims
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claim public.expense_claims;
begin
  if not public.is_ops_staff() then
    raise exception 'verify_expense_claim: master or operation_admin role required';
  end if;
  select * into v_claim from public.expense_claims where id = p_claim_id and org_id = public.current_org_id();
  if v_claim.id is null then
    raise exception 'verify_expense_claim: claim % not found', p_claim_id;
  end if;
  if p_verified_amount is null or p_verified_amount < 0 then
    raise exception 'verify_expense_claim: verified_amount must be a non-negative number';
  end if;
  if p_verified_amount is distinct from v_claim.submitted_amount and nullif(btrim(p_reason), '') is null then
    raise exception 'verify_expense_claim: reason is required when the verified amount differs from the submitted amount';
  end if;

  update public.expense_claims
  set verified_amount = p_verified_amount,
      verified_by = auth.uid(),
      verified_at = now(),
      reason = nullif(btrim(p_reason), '')
  where id = p_claim_id
  returning * into v_claim;

  return v_claim;
end;
$$;

grant execute on function public.verify_expense_claim(uuid, numeric, text) to authenticated;
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from public, anon;

-- Monthly verified totals per technician, by claim type — the figures Units
-- 6/7 read. Unverified rows are excluded by construction (verified_amount is
-- the gate).
create or replace function public.technician_expense_claims_total(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date,
  p_claim_type text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(verified_amount), 0)
  from public.expense_claims
  where org_id = p_org_id
    and technician_id = p_technician_id
    and claim_type = p_claim_type
    and period = date_trunc('month', p_period)::date
    and verified_amount is not null;
$$;

grant execute on function public.technician_expense_claims_total(uuid, uuid, date, text) to authenticated;
revoke execute on function public.technician_expense_claims_total(uuid, uuid, date, text) from public, anon;
$m3body$;
  v_m4 text := $m4body$
-- Monthly Expenses spec, Unit 4 — recharge allowances, the generic
-- adjustment mechanism, and the own-bike allowance org setting
-- (§1.1/§1.6/§1.7/§3.4/§3.5/§3.6).
--
-- `monthly_adjustments` is the one mechanism for every top-up and exclusion
-- (§3.5), scoped to `recharge` and `bike_allowance` only. Petrol and
-- maintenance do NOT use this table — the owner's revision (superseding the
-- "override" idea originally built here) is that the verified claim amount
-- (Unit 3) already IS the figure that pays, and verifying at zero already
-- IS how an admin refuses one. A separate adjustment row on top of that
-- would be a second way to say the same thing, so this table carries no
-- `petrol`/`maintenance` target at all.

create table public.person_allowances (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  -- Deliberately `profiles`, not `technicians` — §1.1: "not restricted to
  -- technicians". A profile with no row here receives no recharge, which is
  -- the whole scoping rule.
  profile_id uuid not null references public.profiles (id) on delete cascade,
  recharge_amount numeric(12, 2) not null check (recharge_amount >= 0),
  effective_from date not null,
  effective_to date,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  exclude using gist (
    profile_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
);

create index person_allowances_org_id_idx on public.person_allowances (org_id);
create index person_allowances_profile_id_idx on public.person_allowances (profile_id, effective_from);

alter table public.person_allowances enable row level security;

create policy person_allowances_select_ops on public.person_allowances
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy person_allowances_write_ops on public.person_allowances for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_person_allowances after insert or update or delete on public.person_allowances
  for each row execute function public.audit_master_change();

create or replace function public.person_allowance_on(
  p_org_id uuid,
  p_profile_id uuid,
  p_date date
)
returns public.person_allowances
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.person_allowances
  where org_id = p_org_id
    and profile_id = p_profile_id
    and effective_from <= p_date
    and coalesce(effective_to, 'infinity'::date) >= p_date
  limit 1;
$$;

grant execute on function public.person_allowance_on(uuid, uuid, date) to authenticated;
revoke execute on function public.person_allowance_on(uuid, uuid, date) from public, anon;

-- ── monthly_adjustments ────────────────────────────────────────────────────

create table public.monthly_adjustments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  period date not null,
  adjustment_target text not null check (adjustment_target in ('recharge', 'bike_allowance')),
  adjustment_type text not null check (adjustment_type in ('top_up', 'exclude')),
  amount numeric(12, 2),
  reason text not null check (btrim(reason) <> ''),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  check (
    (adjustment_type = 'exclude' and amount is null)
    or (adjustment_type = 'top_up' and amount is not null and amount > 0)
  )
);

create index monthly_adjustments_org_id_idx on public.monthly_adjustments (org_id);
create index monthly_adjustments_lookup_idx on public.monthly_adjustments (profile_id, period, adjustment_target);

alter table public.monthly_adjustments enable row level security;

create policy monthly_adjustments_select_ops on public.monthly_adjustments
  for select using (org_id = public.current_org_id() and public.is_ops_staff());
create policy monthly_adjustments_write_ops on public.monthly_adjustments for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create trigger audit_monthly_adjustments after insert or update or delete on public.monthly_adjustments
  for each row execute function public.audit_master_change();

create or replace function public.monthly_adjustment_top_up(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(amount), 0)
  from public.monthly_adjustments
  where org_id = p_org_id
    and profile_id = p_profile_id
    and period = date_trunc('month', p_period)::date
    and adjustment_target = p_target
    and adjustment_type = 'top_up';
$$;

create or replace function public.monthly_adjustment_excluded(
  p_org_id uuid,
  p_profile_id uuid,
  p_period date,
  p_target text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.monthly_adjustments
    where org_id = p_org_id
      and profile_id = p_profile_id
      and period = date_trunc('month', p_period)::date
      and adjustment_target = p_target
      and adjustment_type = 'exclude'
  );
$$;

grant execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) to authenticated;
grant execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) to authenticated;
revoke execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) from public, anon;
revoke execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) from public, anon;

-- ── Org setting: own-bike allowance base (§1.6/§3.6) ──────────────────────
-- Appended to the existing single-row-per-org `settings` table, matching
-- every other org-wide numeric config in this codebase
-- (20260701091100_system.sql's own header: "one typed row per org, not a
-- generic key/value table"). `settings_write_master` (20260701091300_rls.sql)
-- is already master-only, matching §1.6's "editable by master" exactly — no
-- RLS change needed here.
-- `audit_settings` (20260702090000_audit_triggers.sql) already covers the
-- whole row on every insert/update/delete — adding a second trigger here
-- would double-write audit_log on every settings change, so this column
-- just rides the existing trigger, no new one.
alter table public.settings
  add column own_bike_allowance_base numeric(12, 2) not null default 1000 check (own_bike_allowance_base >= 0);
$m4body$;
  v_m5 text := $m5body$
-- Monthly Expenses spec, Unit 5 — own-bike allowance flows into
-- compute_incentives (§1.6/§1.9). This is the ONLY item from this feature
-- that touches incentives; the other three (recharge, petrol, maintenance)
-- are reimbursements and only ever appear in compute_salary (Unit 6).
--
-- Built against the REAL live body — the one after
-- 20261016150000_review_incentives_switch.sql, itself built on
-- 20261016120000_installation_incentive_credits.sql and
-- 20261016110000_test_customer_flag.sql. All three live-only components
-- are carried forward untouched: the credit_source aggregation block, the
-- _visit_is_test/_ticket_is_test exclusions, and the
-- review_incentives_enabled gate (default OFF, Google Maps policy
-- compliance) — that gate is explicitly untouchable per instruction.
--
-- incentives_earned's one-source check widens from 3-way to 4-way:
-- rule_id, installation_rate_id, credit_source, is_bike_allowance — exactly
-- one set. For any row where is_bike_allowance is false (true of every row
-- that exists today, since the column is new), the new check reduces to
--   (rule_id is not null)::int + (installation_rate_id is not null)::int + (credit_source is not null)::int = 1
-- which is exactly the live 3-way predicate — adding a false 4th term to a
-- sum changes nothing. No row the 3-way check accepted or rejected changes
-- behaviour under the 4-way check.

alter table public.incentives_earned
  add column is_bike_allowance boolean not null default false;

alter table public.incentives_earned drop constraint incentives_earned_one_source;

alter table public.incentives_earned
  add constraint incentives_earned_one_source check (
    (case when rule_id is not null then 1 else 0 end)
    + (case when installation_rate_id is not null then 1 else 0 end)
    + (case when credit_source is not null then 1 else 0 end)
    + (case when is_bike_allowance then 1 else 0 end) = 1
  );

create unique index incentives_earned_bike_allowance_unique_idx
  on public.incentives_earned (technician_id, period)
  where is_bike_allowance;

-- compute_incentives: verbatim live body (20261016150000_review_incentives_
-- switch.sql) up to and including the installation-ticket-credits block,
-- with one new block appended just before the final `return query` —
-- marked below. Nothing above that marker changed.
create or replace function public.compute_incentives(p_org_id uuid, p_period date)
 RETURNS SETOF incentives_earned
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
  v_review_enabled boolean;
  -- Unit 5 additions, own-bike allowance block only.
  v_bike_tech record;
  v_own_days integer;
  v_days_in_month integer;
  v_base_setting numeric(12, 2);
  v_prorated numeric(12, 2);
  v_extra numeric(12, 2);
  v_excluded boolean;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  -- Google's policy forbids rewarding reviews: the 'review' rule type only pays while the master has switched this ON
  -- (default OFF). Existing rules and rows are untouched; the switch only stops new computations.
  select coalesce(s.review_incentives_enabled, false) into v_review_enabled from public.settings s where s.org_id = p_org_id;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id and is_active loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      -- A rule set to ₹0 pays nothing: no zero-amount rows.
      if v_rule.amount <= 0 then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        v_metric := public.technician_attributed_sales(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'review' and v_review_enabled then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and not public._visit_is_test(v.id)
          and r.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and r.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'finder_credit' then
        v_metric := public.technician_finder_conversions(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'installation' then
        v_metric := public.technician_installation_count(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  -- Per-unit installation rates (additive to the flat-threshold rule above).
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    for v_rate in
      select m.rate_id, sum(m.qty)::int as qty, ra.flat_amount
      from (
        select il.qty, public.installation_rate_for(p_org_id, il.product_id) as rate_id
        from public.installations_logged il
        where il.org_id = p_org_id
          and il.technician_id = v_tech.id
          -- already paid by an installation-ticket credit (pending or approved): never counted twice
          and not exists (
            select 1 from public.installation_incentive_credits c
            where c.visit_id = il.visit_id and c.product_id = il.product_id and c.status <> 'void'
          )
          and not public._visit_is_test(il.visit_id)
          and il.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
          and il.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      ) m
      join public.installation_incentive_rates ra on ra.id = m.rate_id
      group by m.rate_id, ra.flat_amount
    loop
      v_amount := v_rate.qty * v_rate.flat_amount;
      if v_amount <= 0 then
        continue;
      end if;
      select id into v_existing_id from public.incentives_earned
        where technician_id = v_tech.id and installation_rate_id = v_rate.rate_id and period = v_period;
      if v_existing_id is null then
        insert into public.incentives_earned (org_id, technician_id, installation_rate_id, amount, period)
        values (p_org_id, v_tech.id, v_rate.rate_id, v_amount, v_period);
      else
        update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
      end if;
    end loop;
  end loop;

  -- Installation-ticket credits: the master-approved credits completed in the month, one row per technician and month.
  -- Recomputed on every run (like the per-unit rates) so a late approval or a void is reflected.
  for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
    select coalesce(sum(c.amount), 0) into v_amount
    from public.installation_incentive_credits c
    where c.org_id = p_org_id
      and c.technician_id = v_tech.id
      and c.status = 'approved'
      and c.created_at >= (v_period::timestamp at time zone 'Asia/Kolkata')
      and c.created_at < ((v_period + interval '1 month')::timestamp at time zone 'Asia/Kolkata')
      and not public._ticket_is_test(c.ticket_id);
    select id into v_existing_id from public.incentives_earned
      where technician_id = v_tech.id and credit_source = 'installation_ticket' and period = v_period;
    if v_existing_id is null then
      if v_amount > 0 then
        insert into public.incentives_earned (org_id, technician_id, credit_source, amount, period)
        values (p_org_id, v_tech.id, 'installation_ticket', v_amount, v_period);
      end if;
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  -- ── Unit 5: own-bike allowance (new block) ──────────────────────────────
  -- Pro-rated by days-in-month on an own bike (technician_own_bike_days,
  -- Unit 1); a company-bike technician or one with no vehicle row at all
  -- gets 0 own-days and so pays 0 — "every existing component of the
  -- incentive total is unchanged" holds because this block only ever
  -- INSERTs a new is_bike_allowance row or UPDATEs one it already owns; it
  -- never touches a rule_id/installation_rate_id/credit_source row.
  select own_bike_allowance_base into v_base_setting from public.settings where org_id = p_org_id;
  v_base_setting := coalesce(v_base_setting, 0);
  v_days_in_month := (v_period + interval '1 month')::date - v_period;

  for v_bike_tech in select id, profile_id from public.technicians where org_id = p_org_id and is_active loop
    v_own_days := public.technician_own_bike_days(p_org_id, v_bike_tech.id, v_period);
    v_prorated := round(v_base_setting * v_own_days / v_days_in_month, 2);
    v_excluded := public.monthly_adjustment_excluded(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_extra := public.monthly_adjustment_top_up(p_org_id, v_bike_tech.profile_id, v_period, 'bike_allowance');
    v_amount := (case when v_excluded then 0 else v_prorated end) + v_extra;

    if v_amount <= 0 then
      continue;
    end if;

    select id into v_existing_id from public.incentives_earned
      where technician_id = v_bike_tech.id and period = v_period and is_bike_allowance;
    if v_existing_id is null then
      insert into public.incentives_earned (org_id, technician_id, is_bike_allowance, amount, period)
      values (p_org_id, v_bike_tech.id, true, v_amount, v_period);
    else
      update public.incentives_earned set amount = v_amount where id = v_existing_id and amount is distinct from v_amount;
    end if;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;

grant execute on function public.compute_incentives(uuid, date) to authenticated;
$m5body$;
  v_m6 text := $m6body$
-- Monthly Expenses spec, Unit 6 — four itemised lines in compute_salary
-- (§1.9/§4 Unit 6, and the owner's revision to §1.3). `compute_salary`
-- returns `salaries` (a plain row type, no existing jsonb/array-of-lines
-- concept anywhere in this codebase — see the Section 2 report), so "never
-- collapsed into a single figure" is met by adding named columns rather
-- than inventing a jsonb shape with no local precedent. No existing column
-- is removed or renamed, so a caller reading only the original 5 fields
-- sees no change.
--
-- Owner revision (supersedes the original §1.3 "km x rate is the payment"
-- design, and removes this file's earlier exclude+top_up override
-- modelling entirely): petrol now behaves exactly like maintenance —
-- `expense_claims.verified_amount` is what is paid, gated the same way
-- (null = nothing paid). Kilometres x rate is kept only as a REFERENCE
-- figure, computed per log entry against whichever technician_vehicles row
-- was effective on that entry's own date
-- (technician_petrol_reference_amount, 20261107100100_technician_km_log.sql)
-- so the admin has something to check the verified amount against. Neither
-- petrol nor maintenance reads monthly_adjustments any more — verifying at
-- zero is the refusal, the verified amount is the correction (Fix 4).
--
-- Important distinction: the own-bike allowance is NOT added to `net` here
-- a second time — Unit 5 already folds it into `incentives_earned`, and
-- `incentives` below already sums that in, same as it always has.
-- `bike_allowance_base/extra/reason` are read back from Unit 1/4/5's own
-- tables purely for display, not a second addition. Recharge/petrol/
-- maintenance ARE new additions to `net` — they didn't exist in the
-- formula before this feature.

alter table public.salaries
  add column recharge_amount numeric(12, 2) not null default 0,
  add column recharge_reason text,
  add column petrol_km numeric(12, 2) not null default 0,
  add column petrol_rate numeric(12, 2) not null default 0,
  add column petrol_reference_amount numeric(12, 2) not null default 0,
  add column petrol_amount numeric(12, 2) not null default 0,
  add column maintenance_amount numeric(12, 2) not null default 0,
  add column bike_allowance_base numeric(12, 2) not null default 0,
  add column bike_allowance_extra numeric(12, 2) not null default 0,
  add column bike_allowance_reason text,
  add column bike_allowance_amount numeric(12, 2) not null default 0;

-- compute_salary: verbatim live body (20261001110000_compute_salary_tier_
-- base.sql) with the itemised-lines block inserted before the final
-- upsert, and the recharge/petrol/maintenance totals folded into `net`
-- alongside the existing base/revenue_component/late_deduction/incentives.
create or replace function public.compute_salary(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns salaries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_base numeric(12, 2);
  v_revenue numeric(12, 2);
  v_late_hours numeric(12, 2);
  v_late_deduction numeric(12, 2);
  v_incentives numeric(12, 2);
  v_row salaries;
  -- Unit 6 additions.
  v_profile_id uuid;
  v_recharge numeric(12, 2);
  v_recharge_reason text;
  v_km numeric(12, 2);
  v_rate numeric(12, 2);
  v_petrol_reference numeric(12, 2);
  v_petrol numeric(12, 2);
  v_maintenance numeric(12, 2);
  v_bike_row incentives_earned;
  v_bike_base numeric(12, 2);
  v_bike_extra numeric(12, 2);
  v_bike_reason text;
  v_bike_amount numeric(12, 2);
begin
  if not public.is_master() then
    raise exception 'compute_salary: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_salary: org mismatch';
  end if;
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = p_org_id) then
    raise exception 'compute_salary: technician % not found in org %', p_technician_id, p_org_id;
  end if;

  select tt.monthly_salary into v_base
  from public.technicians t
  join public.technician_tiers tt on tt.id = t.tier_id
  where t.id = p_technician_id;
  if v_base is null then
    select tt.monthly_salary into v_base
    from public.technician_tiers tt
    where tt.org_id = p_org_id and tt.rank = 1;
  end if;
  v_base := coalesce(v_base, 0);

  v_revenue := public.technician_attributed_revenue(p_org_id, p_technician_id, v_period);
  v_late_hours := public.technician_late_hours(p_org_id, p_technician_id, v_period);
  -- v2.2: "late deduction hours x 2" — see original definition.
  v_late_deduction := round(v_late_hours * 2, 2);

  select coalesce(sum(amount), 0) into v_incentives
  from public.incentives_earned
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  -- ── Monthly Expenses itemised lines ──────────────────────────────────
  select profile_id into v_profile_id from public.technicians where id = p_technician_id;

  -- Recharge: a flat allowance set per person; no amount set is the whole
  -- scoping rule (§1.1). Still uses monthly_adjustments (recharge was never
  -- part of the petrol/maintenance revision).
  select coalesce(recharge_amount, 0) into v_recharge
  from public.person_allowance_on(p_org_id, v_profile_id, v_period);
  v_recharge := coalesce(v_recharge, 0);
  if public.monthly_adjustment_excluded(p_org_id, v_profile_id, v_period, 'recharge') then
    v_recharge := 0;
  end if;
  v_recharge := v_recharge + public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'recharge');
  select reason into v_recharge_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'recharge'
    order by created_at desc limit 1;

  -- Petrol — owner revision: the verified claim amount is what is paid,
  -- exactly like maintenance (see technician_expense_claims_total, Unit 3).
  -- km/rate/reference are informational only, shown so the admin can see
  -- what they checked the verified amount against; `petrol_rate` is the
  -- technician's currently-effective rate for context, while
  -- petrol_reference_amount is priced per log entry at whatever rate was
  -- effective on that entry's own date (handles a rate that changed
  -- mid-month correctly — see technician_petrol_reference_amount).
  v_km := public.technician_km_log_sum(p_org_id, p_technician_id, v_period);
  select coalesce(petrol_rate_per_km, 0) into v_rate
  from public.technician_vehicle_on(p_org_id, p_technician_id, (v_period + interval '1 month' - interval '1 day')::date);
  v_rate := coalesce(v_rate, 0);
  v_petrol_reference := public.technician_petrol_reference_amount(p_org_id, p_technician_id, v_period);
  v_petrol := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'petrol');

  -- Maintenance: only a verified claim reaches salary (§1.4) —
  -- technician_expense_claims_total already excludes unverified rows. No
  -- monthly_adjustments involvement (Fix 4): verifying at zero is the
  -- refusal, the verified amount is the correction.
  v_maintenance := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'maintenance');

  -- Own-bike allowance: display only — the figure is already inside
  -- v_incentives above via Unit 5, never added twice.
  select * into v_bike_row from public.incentives_earned
    where technician_id = p_technician_id and period = v_period and is_bike_allowance;
  select own_bike_allowance_base into v_bike_base from public.settings where org_id = p_org_id;
  v_bike_base := coalesce(v_bike_base, 0);
  v_bike_extra := public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'bike_allowance');
  select reason into v_bike_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'bike_allowance'
    order by created_at desc limit 1;
  v_bike_amount := coalesce(v_bike_row.amount, 0);

  insert into public.salaries (
    org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net,
    recharge_amount, recharge_reason, petrol_km, petrol_rate, petrol_reference_amount, petrol_amount,
    maintenance_amount, bike_allowance_base, bike_allowance_extra, bike_allowance_reason, bike_allowance_amount
  )
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives,
    v_base + v_revenue - v_late_deduction + v_incentives + v_recharge + v_petrol + v_maintenance,
    v_recharge, v_recharge_reason, v_km, v_rate, v_petrol_reference, v_petrol,
    v_maintenance, v_bike_base, v_bike_extra, v_bike_reason, v_bike_amount
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net,
    recharge_amount = excluded.recharge_amount,
    recharge_reason = excluded.recharge_reason,
    petrol_km = excluded.petrol_km,
    petrol_rate = excluded.petrol_rate,
    petrol_reference_amount = excluded.petrol_reference_amount,
    petrol_amount = excluded.petrol_amount,
    maintenance_amount = excluded.maintenance_amount,
    bike_allowance_base = excluded.bike_allowance_base,
    bike_allowance_extra = excluded.bike_allowance_extra,
    bike_allowance_reason = excluded.bike_allowance_reason,
    bike_allowance_amount = excluded.bike_allowance_amount
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;
revoke execute on function public.compute_salary(uuid, uuid, date) from public, anon;
$m6body$;
  v_t1 text := $t1body$
-- Rolled-back check for 20261107100000_technician_vehicles.sql. Run through
-- the Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_tech uuid; v_techid uuid; v_tech2id uuid;
  v_ok boolean;
  v_days int;
  v_row public.technician_vehicles;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.id into v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Overlapping ranges rejected by the database
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'own', 2.5, '2026-01-01', '2026-01-20');
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
      values (v_org, v_techid, 'company', 0, '2026-01-10', '2026-01-25');
    res := res || E'\n' || 'overlapping range: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlapping range: rejected ('||sqlerrm||')';
  end;

  -- Current ownership resolves correctly for a technician with one row
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-15');
  res := res || E'\n' || format('single-row resolve: ownership=%s rate=%s', v_row.ownership, v_row.petrol_rate_per_km);

  delete from technician_vehicles where technician_id = v_techid;

  -- Mid-month switch on the 12th of a 31-day month (January): 11 own, 20 company
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'own', 3, '2026-01-01', '2026-01-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'company', 0, '2026-01-12', null);
  select technician_own_bike_days(v_org, v_techid, '2026-01-01') into v_days;
  res := res || E'\n' || format('mid-month switch own days (expect 11): %s', v_days);
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-20');
  res := res || E'\n' || format('ownership on the 20th (expect company): %s', v_row.ownership);
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-11');
  res := res || E'\n' || format('ownership on the 11th (expect own): %s', v_row.ownership);

  delete from technician_vehicles where technician_id = v_techid;

  -- Technician with no row: resolves to no ownership/rate, nothing crashes
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s, ownership is null = %s', v_row.id is null, v_row.ownership is null);
  select technician_own_bike_days(v_org, v_techid, '2026-01-01') into v_days;
  res := res || E'\n' || format('no-row own days (expect 0): %s', v_days);

  -- A technician cannot read or write this table
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
    values (v_org, v_techid, 'own', 3, '2026-02-01');
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) = 0 into v_ok from technician_vehicles where technician_id = v_techid;
  res := res || E'\n' || format('technician SELECT sees nothing: %s', v_ok);
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
      values (v_org, v_techid, 'own', 1, '2026-03-01');
    res := res || E'\n' || 'technician INSERT: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician INSERT: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t1body$;
  v_t2 text := $t2body$
-- Rolled-back check for 20261107100100_technician_km_log.sql. Run through
-- the Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_tech uuid; v_techid uuid; v_tech2id uuid; v_tech2 uuid;
  v_sum numeric; v_id uuid; v_n int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.profile_id, t.id into v_tech2, v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Entries accumulate; the monthly sum is the sum of entries
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-05', 10);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-20', 15.5);
  select technician_km_log_sum(v_org, v_techid, '2026-01-01') into v_sum;
  res := res || E'\n' || format('monthly sum (expect 25.5): %s', v_sum);

  -- An entry dated outside the filtered range does not appear and does not count
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-02-01', 99);
  select technician_km_log_sum(v_org, v_techid, '2026-01-01') into v_sum;
  res := res || E'\n' || format('January sum unaffected by February entry (expect 25.5): %s', v_sum);

  -- The monthly sum for a technician with no entries is zero, not null
  select technician_km_log_sum(v_org, v_tech2id, '2026-01-01') into v_sum;
  res := res || E'\n' || format('no-entries sum (expect 0, not null): %s, is null = %s', v_sum, v_sum is null);

  -- There is no code path that updates or deletes an entry — default-deny:
  -- no update/delete policy exists at all, even for master. Checked as
  -- 'authenticated'/master, not the superuser connection running this
  -- block, since RLS does not apply to a superuser/BYPASSRLS role at all
  -- regardless of policies.
  select id into v_id from technician_km_log where technician_id = v_techid order by entry_date limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    update technician_km_log set km = 1 where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('UPDATE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'UPDATE km_log as master: rejected ('||sqlerrm||')';
  end;
  begin
    delete from technician_km_log where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('DELETE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'DELETE km_log as master: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- A technician reads only their own entries
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_km_log where technician_id = v_techid;
  res := res || E'\n' || format('technician2 sees technician1 rows (expect 0): %s', v_n);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_tech2id, '2026-01-07', 5);
  select count(*) into v_n from technician_km_log where technician_id = v_tech2id;
  res := res || E'\n' || format('technician2 sees own rows after own insert (expect 1): %s', v_n);
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-08', 5);
    res := res || E'\n' || 'technician2 INSERT for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 INSERT for technician1: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t2body$;
  v_t3 text := $t3body$
-- Rolled-back check for 20261107100200_expense_claims.sql. Run through the
-- Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
--
-- Not exercised here (needs the real Storage HTTP API, not plain SQL): bucket
-- file_size_limit / allowed_mime_types enforcement on an actual upload. The
-- storage.objects RLS policies themselves are checked below.
do $t$
declare
  res text := '';
  v_org uuid; v_tech uuid; v_techid uuid; v_tech2 uuid; v_tech2id uuid; v_master uuid;
  v_claim public.expense_claims; v_n int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.profile_id, t.id into v_tech2, v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Technician submits a claim via the RPC (identity resolved server-side)
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 500, v_techid::text || '/bill1.jpg', '2026-01-01');
  execute 'reset role';
  res := res || E'\n' || format('submitted claim: verified_amount is null = %s', v_claim.verified_amount is null);

  -- A claim with verified_amount null is invisible to salary/the report
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('unverified claim total (expect 0): %s', v_n);

  -- verified_amount differing from submitted_amount with a null reason is
  -- rejected by the database (CHECK constraint), not just the form
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform verify_expense_claim(v_claim.id, 300, null);
    res := res || E'\n' || 'verify with differing amount + null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'verify with differing amount + null reason: rejected ('||sqlerrm||')';
  end;

  -- Same amount, no reason needed: succeeds
  select * into v_claim from verify_expense_claim(v_claim.id, 500, null);
  res := res || E'\n' || format('verify same amount, no reason: verified_amount=%s', v_claim.verified_amount);
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('verified claim total (expect 500): %s', v_n);

  -- A verified amount of zero behaves as a rejection: nothing paid, row and
  -- photo path survive, reason is readable
  select * into v_claim from verify_expense_claim(v_claim.id, 0, 'bill illegible, rejected');
  res := res || E'\n' || format('verify at zero: verified_amount=%s reason=%s photo_survives=%s', v_claim.verified_amount, v_claim.reason, v_claim.bill_photo_path is not null);
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('total after zero-verify (expect 0): %s', v_n);
  select count(*) into v_n from expense_claims where id = v_claim.id;
  res := res || E'\n' || format('row still exists after zero-verify (expect 1): %s', v_n);
  execute 'reset role';

  -- A technician cannot read another technician's claim
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from expense_claims where technician_id = v_techid;
  res := res || E'\n' || format('technician2 reading technician1 claims (expect 0): %s', v_n);
  begin
    perform verify_expense_claim(v_claim.id, 1, 'trying to verify as a technician');
    res := res || E'\n' || 'technician verify_expense_claim: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician verify_expense_claim: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- The photograph bucket is not publicly reachable without authentication
  execute 'set local role anon';
  select count(*) into v_n from storage.objects where bucket_id = 'expense-claim-photos';
  res := res || E'\n' || format('anon SELECT on expense-claim-photos bucket rows (expect 0): %s', v_n);
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
$t3body$;
  v_t4 text := $t4body$
-- Rolled-back check for 20261107100300_person_allowances_and_adjustments.sql.
-- Run through the Management API (database/query); it always ends in a
-- RAISE so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_profile uuid; v_profile2 uuid; v_row public.person_allowances;
  v_n int; v_base numeric; v_excluded boolean;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_profile from profiles where org_id = v_org limit 1;
  select id into v_profile2 from profiles where org_id = v_org and id <> v_profile limit 1;

  -- A person with no person_allowances row receives no recharge
  select * into v_row from person_allowance_on(v_org, v_profile2, '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s', v_row.id is null);

  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_profile, 300, '2026-01-01');

  -- A top-up with a null reason is rejected by the database
  begin
    insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
      values (v_org, v_profile, '2026-01-01', 'recharge', 'top_up', 200, null);
    res := res || E'\n' || 'top_up with null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'top_up with null reason: rejected ('||sqlerrm||')';
  end;

  -- A top-up with a reason succeeds and sums correctly
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_profile, '2026-01-01', 'recharge', 'top_up', 200, 'extra data plan this month');
  select monthly_adjustment_top_up(v_org, v_profile, '2026-01-01', 'recharge') into v_base;
  res := res || E'\n' || format('recharge top-up total (expect 200): %s', v_base);

  -- An exclusion for one month affects that month only
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_profile, '2026-02-01', 'recharge', 'exclude', null, 'customer complaint, withheld for February');
  select monthly_adjustment_excluded(v_org, v_profile, '2026-02-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('February excluded (expect true): %s', v_excluded);
  select monthly_adjustment_excluded(v_org, v_profile, '2026-01-01', 'recharge') into v_excluded;
  res := res || E'\n' || format('January NOT excluded (expect false): %s', v_excluded);

  -- Ending a person's allowance row stops future months without altering past ones
  update person_allowances set effective_to = '2026-01-31' where profile_id = v_profile;
  select * into v_row from person_allowance_on(v_org, v_profile, '2026-01-15');
  res := res || E'\n' || format('January still resolves (expect 300): %s', v_row.recharge_amount);
  select * into v_row from person_allowance_on(v_org, v_profile, '2026-03-01');
  res := res || E'\n' || format('March after ending the row (expect id is null): %s', v_row.id is null);

  -- An adjustment belonging to another organisation is not visible or applicable
  declare v_other_master uuid;
  begin
    select id into v_other_master from profiles where role='master' and org_id <> v_org limit 1;
    if v_other_master is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_other_master, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into v_n from monthly_adjustments where profile_id = v_profile;
      res := res || E'\n' || format('other-org master sees this org''s adjustments (expect 0): %s', v_n);
      execute 'reset role';
    else
      res := res || E'\n' || 'other-org master check: skipped (no second organisation in this database)';
    end if;
  end;

  raise exception E'RESULTS%', res;
end $t$;
$t4body$;
  v_t5 text := $t5body$
-- Rolled-back check for 20261107100400_compute_incentives_bike_allowance.sql,
-- rebuilt against the real live body (after 20261016150000_review_
-- incentives_switch, itself after 20261016120000_installation_incentive_
-- credits and 20261016110000_test_customer_flag). Uses its own throwaway
-- organisation so this test's incentive_rules/credit rows never interact
-- with another org's data. Run through the Management API (database/query);
-- it always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid; v_t3 uuid; v_t3p uuid; v_t4 uuid; v_t4p uuid;
  v_amount numeric; v_n int; v_base numeric; v_reason text;
  v_before_count int; v_after_count int;
  v_rule_id uuid;
  v_credit_row incentives_earned;
begin
  insert into organizations (name) values ('__TEST_monthly_expenses_bike_allowance') returning id into v_org;
  insert into settings (org_id) values (v_org);
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'bike-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  v_t1 := gen_random_uuid(); v_t2 := gen_random_uuid(); v_t3 := gen_random_uuid(); v_t4 := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 't1@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 't2@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t3, 'authenticated', 'authenticated', 't3@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t4, 'authenticated', 'authenticated', 't4@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t3, v_org, '__TEST_ tech3', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t4, v_org, '__TEST_ tech4', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1p;
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2p;
  insert into technicians (org_id, profile_id) values (v_org, v_t3) returning id into v_t3p;
  insert into technicians (org_id, profile_id) values (v_org, v_t4) returning id into v_t4p;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Technician on their own bike all month receives the full base amount
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t1p, 'own', 2, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('own all month (expect base=%s): %s', v_base, v_amount);

  -- Technician on a company bike all month receives nothing
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t2p, 'company', 0, '2026-04-01', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_t2p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('company all month, rows created (expect 0): %s', v_n);

  -- Mid-month switch (own 1-11, company 12-30 in a 30-day April)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3p, 'own', 2, '2026-04-01', '2026-04-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t3p, 'company', 0, '2026-04-12', '2026-04-30');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('mid-month switch (expect round(%s*11/30,2)=%s): %s', v_base, round(v_base * 11 / 30, 2), v_amount);

  -- An extra with a reason adds on top, and the reason is retrievable
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_t3, '2026-04-01', 'bike_allowance', 'top_up', 150, 'new tyres this month, approved by master');
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t3p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('with extra (expect prorated+150=%s): %s', round(v_base * 11 / 30, 2) + 150, v_amount);
  select reason into v_reason from monthly_adjustments where profile_id = v_t3 and adjustment_target = 'bike_allowance' limit 1;
  res := res || E'\n' || format('extra reason retrievable: %s', v_reason);

  -- Every existing component of the incentive total is unchanged: a
  -- technician with NO vehicle row produces no bike-allowance row, and
  -- re-running compute_incentives for them is a no-op (idempotent).
  select count(*) into v_before_count from incentives_earned where technician_id = v_t4p and period = '2026-04-01';
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_after_count from incentives_earned where technician_id = v_t4p and period = '2026-04-01';
  res := res || E'\n' || format('no-vehicle technician row count before=%s after=%s (expect equal)', v_before_count, v_after_count);
  select count(*) into v_n from incentives_earned where technician_id = v_t4p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('no-vehicle technician bike-allowance rows (expect 0): %s', v_n);

  -- The bike-allowance row and a credit_source row coexist for the same
  -- technician/period without violating the widened 4-way constraint
  -- (the credit row is inserted directly here, bypassing the real ticket/
  -- approval flow, which is out of scope for this test). The live
  -- installation-ticket-credits block recomputes its figure from
  -- installation_incentive_credits on EVERY run regardless of what this
  -- feature does — with no real backing credit row, the verbatim-preserved
  -- block correctly overwrites the manually-seeded 500 down to 0. That is
  -- the real live behaviour (by design, so a late void is reflected) and
  -- confirms the bike-allowance block did not change it: it is testing the
  -- live block exactly as it already worked before this feature existed.
  insert into incentives_earned (org_id, technician_id, credit_source, amount, period)
    values (v_org, v_t1p, 'installation_ticket', 500, '2026-04-01');
  perform compute_incentives(v_org, '2026-04-01');
  select count(*) into v_n from incentives_earned where technician_id = v_t1p and period = '2026-04-01';
  res := res || E'\n' || format('bike-allowance + credit_source coexist for same technician/period (expect 2 rows): %s', v_n);
  select * into v_credit_row from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and credit_source = 'installation_ticket';
  res := res || E'\n' || format('credit_source row recomputed from the (empty) real credits table, unrelated to this feature (expect 0, not the seeded 500): %s', v_credit_row.amount);

  -- The review_incentives_enabled switch (default OFF) does not affect the
  -- bike-allowance block either way.
  update settings set review_incentives_enabled = true where org_id = v_org;
  perform compute_incentives(v_org, '2026-04-01');
  select amount into v_amount from incentives_earned where technician_id = v_t1p and period = '2026-04-01' and is_bike_allowance;
  res := res || E'\n' || format('bike allowance unaffected by review switch ON (still expect base=%s): %s', v_base, v_amount);

  -- Malformed rows: the widened 4-way check still rejects two sources set,
  -- and still rejects zero sources set — exactly what the narrower 3-way
  -- check (installation_incentive_credits) already rejected.
  insert into incentive_rules (org_id, type, threshold, amount) values (v_org, 'service_income', 1000, 100) returning id into v_rule_id;
  begin
    insert into incentives_earned (org_id, technician_id, rule_id, installation_rate_id, amount, period)
      values (v_org, v_t2p, v_rule_id, gen_random_uuid(), 10, '2026-04-01');
    res := res || E'\n' || 'two sources set: SUCCEEDED (bad, unless no incentive_rules row exists to reference)';
  exception when others then
    res := res || E'\n' || 'two sources set: rejected ('||sqlerrm||')';
  end;
  begin
    insert into incentives_earned (org_id, technician_id, amount, period) values (v_org, v_t2p, 10, '2026-04-01');
    res := res || E'\n' || 'zero sources set: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'zero sources set: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t5body$;
  v_t6 text := $t6body$
-- Rolled-back check for 20261107100500_compute_salary_itemised_expenses.sql.
-- Run through the Management API (database/query); it always ends in a
-- RAISE so nothing persists. Read the RESULTS in the error.
--
-- Not exercised here (needs a browser): "if the return shape changed, the
-- frontend renders the new shape correctly" — verified instead by the
-- SalaryTab.tsx/hr.ts SalaryRow type update described in the build report.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid;
  v_row salaries; v_row2 salaries;
  v_petrol_claim public.expense_claims;
  v_maint_claim public.expense_claims;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.id, t.profile_id into v_t1, v_t1p from technicians t limit 1;
  select t.id, t.profile_id into v_t2, v_t2p from technicians t where t.id <> v_t1 limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- A technician with none of the four produces salary output identical to
  -- before this feature: all four new areas are 0 and net reduces to the
  -- original base + revenue_component - late_deduction + incentives formula.
  select * into v_row2 from compute_salary(v_org, v_t2, '2026-05-01');
  res := res || E'\n' || format(
    'no-data technician: recharge=%s petrol_amount=%s petrol_reference=%s maintenance=%s bike_extra=%s, net == old formula: %s',
    v_row2.recharge_amount, v_row2.petrol_amount, v_row2.petrol_reference_amount, v_row2.maintenance_amount, v_row2.bike_allowance_extra,
    v_row2.net = v_row2.base + v_row2.revenue_component - v_row2.late_deduction + v_row2.incentives
  );

  -- Set up all four for v_t1: recharge allowance, vehicle+km (petrol
  -- reference), a verified petrol claim, a verified maintenance claim, and
  -- own-bike allowance (via Unit 1/5).
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_t1p, 250, '2026-05-01');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_t1, 'own', 4, '2026-05-01', '2026-05-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_t1, '2026-05-10', 50);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_petrol_claim from submit_expense_claim(v_org, 'petrol', 150, v_t1::text || '/petrol_bill.jpg', '2026-05-01');
  select * into v_maint_claim from submit_expense_claim(v_org, 'maintenance', 300, v_t1::text || '/bill.jpg', '2026-05-01');
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  -- Verified lower than the reference figure (km*rate=200) — the admin's
  -- judgement call is what pays, the reference figure is just context.
  perform verify_expense_claim(v_petrol_claim.id, 180, 'bill partly illegible, approved a reduced amount');
  perform verify_expense_claim(v_maint_claim.id, 300, null);
  perform compute_incentives(v_org, '2026-05-01');

  select * into v_row from compute_salary(v_org, v_t1, '2026-05-01');

  -- All four lines appear separately
  res := res || E'\n' || format(
    'all-four technician: recharge=%s petrol_amount=%s maintenance=%s bike_allowance_amount=%s',
    v_row.recharge_amount, v_row.petrol_amount, v_row.maintenance_amount, v_row.bike_allowance_amount
  );

  -- The petrol line shows kilometres, the rate, the computed reference
  -- figure, AND the amount actually paid — four values, verified amount (180)
  -- is what's paid, the reference figure (km*rate=200) is informational only.
  res := res || E'\n' || format(
    'petrol breakdown: km=%s rate=%s reference=%s(expect 200) paid=%s(expect 180, NOT the reference figure)',
    v_row.petrol_km, v_row.petrol_rate, v_row.petrol_reference_amount, v_row.petrol_amount
  );

  -- The itemised lines sum to the totals the function reports (petrol_amount
  -- is the verified/paid figure, not the reference)
  res := res || E'\n' || format(
    'net reconciles: %s (net=%s, sum=%s)',
    v_row.net = v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount,
    v_row.net,
    v_row.base + v_row.revenue_component - v_row.late_deduction + v_row.incentives + v_row.recharge_amount + v_row.petrol_amount + v_row.maintenance_amount
  );

  -- A petrol claim with verified_amount null pays nothing, same gate as
  -- maintenance, and no monthly_adjustments involvement is needed any more.
  declare v_t3 uuid; v_t3p uuid; v_pending public.expense_claims; v_row3 salaries;
  begin
    select t.id, t.profile_id into v_t3, v_t3p from technicians t where t.id not in (v_t1, v_t2) limit 1;
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_t3p, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_pending from submit_expense_claim(v_org, 'petrol', 500, v_t3::text || '/bill.jpg', '2026-05-01');
    execute 'reset role';
    perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select * into v_row3 from compute_salary(v_org, v_t3, '2026-05-01');
    res := res || E'\n' || format('unverified petrol claim pays nothing (expect 0): %s', v_row3.petrol_amount);
  end;

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t6body$;
  v_t7 text := $t7body$
-- Rolled-back check for Unit 7 (monthly report). The report itself is a
-- frontend aggregation over `salaries` (see src/services/reports.ts's
-- getMonthlyExpensesReport) — same convention as every other report tab in
-- this codebase (no SQL view/function). This test verifies the invariants
-- that aggregation depends on: unverified claims and excluded amounts never
-- reach `salaries` in the first place, and the per-technician figures sum
-- to the org total by construction (plain SUM over the same column). Run
-- through the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1p uuid; v_t2 uuid; v_t2p uuid;
  v_claim public.expense_claims;
  v_sum numeric; v_org_total numeric;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.id, t.profile_id into v_t1, v_t1p from technicians t limit 1;
  select t.id, t.profile_id into v_t2, v_t2p from technicians t where t.id <> v_t1 limit 1;

  -- Submitted as the technician (submit_expense_claim resolves identity
  -- from current_technician_id(), so the caller must actually be one).
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 400, v_t1::text || '/bill.jpg', '2026-06-01');
  execute 'reset role';

  -- An unverified maintenance claim never reaches salary / the report
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('unverified claim excluded from salaries.maintenance_amount (expect 0): %s', v_sum);

  -- Verify it, then re-verify at zero — Fix 4: neither petrol nor
  -- maintenance uses monthly_adjustments any more; re-verifying at zero IS
  -- how an admin withholds a previously-verified claim. The report (reading
  -- salaries) must show 0, not the earlier verified figure.
  perform verify_expense_claim(v_claim.id, 400, null);
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('verified claim reaches salary before withholding (expect 400): %s', v_sum);

  perform verify_expense_claim(v_claim.id, 0, 'disputed bill, withheld pending review');
  perform compute_salary(v_org, v_t1, '2026-06-01');
  select maintenance_amount into v_sum from salaries where technician_id = v_t1 and period = '2026-06-01';
  res := res || E'\n' || format('withheld (re-verified at zero) shows 0 in salaries (expect 0): %s', v_sum);

  -- The organisation total equals the sum of the per-technician figures
  perform compute_salary(v_org, v_t2, '2026-06-01');
  select sum(maintenance_amount + recharge_amount + petrol_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-06-01' and technician_id in (v_t1, v_t2);
  select coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_t1 and period='2026-06-01'), 0)
       + coalesce((select maintenance_amount + recharge_amount + petrol_amount from salaries where technician_id = v_t2 and period='2026-06-01'), 0)
    into v_sum;
  res := res || E'\n' || format('org total equals sum of per-technician figures: %s (org=%s, manual_sum=%s)', v_org_total = v_sum, v_org_total, v_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t7body$;
  v_t8 text := $t8body$
-- Unit 8 — end to end. One month, one organisation, seven technicians:
-- own bike all month, company bike all month, mid-month switch, an excluded
-- month, a top-up, a claim verified lower than submitted, and no expenses at
-- all. Rolled-back check — run through the Management API (database/query);
-- it always ends in a RAISE so nothing persists. Read the RESULTS in the
-- error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_own uuid; v_own_p uuid;
  v_company uuid; v_company_p uuid;
  v_switch uuid; v_switch_p uuid;
  v_excluded uuid; v_excluded_p uuid;
  v_topup uuid; v_topup_p uuid;
  v_lowball uuid; v_lowball_p uuid;
  v_none uuid; v_none_p uuid;
  v_row salaries; v_none_before salaries; v_none_after salaries;
  v_claim public.expense_claims;
  v_base numeric;
  v_org_total numeric; v_manual_sum numeric;
  ids uuid[];
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select own_bike_allowance_base into v_base from settings where org_id = v_org;

  select array_agg(id) into ids from (select id from technicians where org_id = v_org limit 7) s;
  if array_length(ids, 1) < 7 then
    raise exception 'RESULTSUnit 8 skipped: this database has fewer than 7 technicians seeded (found %)', array_length(ids, 1);
  end if;
  v_own := ids[1]; v_company := ids[2]; v_switch := ids[3]; v_excluded := ids[4];
  v_topup := ids[5]; v_lowball := ids[6]; v_none := ids[7];
  select profile_id into v_own_p from technicians where id = v_own;
  select profile_id into v_company_p from technicians where id = v_company;
  select profile_id into v_switch_p from technicians where id = v_switch;
  select profile_id into v_excluded_p from technicians where id = v_excluded;
  select profile_id into v_topup_p from technicians where id = v_topup;
  select profile_id into v_lowball_p from technicians where id = v_lowball;
  select profile_id into v_none_p from technicians where id = v_none;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- The no-expenses technician: snapshot salary before touching anything.
  select * into v_none_before from compute_salary(v_org, v_none, '2026-07-01');

  -- Own bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_own, 'own', 3, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_own, '2026-07-10', 40);

  -- Company bike all month
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_company, 'company', 0, '2026-07-01', '2026-07-31');
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_company, '2026-07-10', 40);

  -- Mid-month switch (own 1-15, company 16-31 — a 31-day month)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'own', 2, '2026-07-01', '2026-07-15');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_switch, 'company', 0, '2026-07-16', '2026-07-31');

  -- Excluded month for the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_excluded_p, 300, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_excluded_p, '2026-07-01', 'recharge', 'exclude', null, 'left mid-month, withheld for July');

  -- Top-up on the recharge allowance
  insert into person_allowances (org_id, profile_id, recharge_amount, effective_from)
    values (v_org, v_topup_p, 250, '2026-07-01');
  insert into monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_topup_p, '2026-07-01', 'recharge', 'top_up', 100, 'extra SIM for the second line this month');

  -- A maintenance claim verified lower than submitted
  perform set_config('request.jwt.claims', json_build_object('sub', v_lowball_p, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 1000, v_lowball::text || '/bill.jpg', '2026-07-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform verify_expense_claim(v_claim.id, 650, 'bill included unrelated personal items');

  perform compute_incentives(v_org, '2026-07-01');

  -- Petrol reference figures are informational (km*rate, Fix 5): neither
  -- technician submitted a petrol claim this month, so petrol_amount (what
  -- is actually paid) is correctly 0 for both regardless of their reference
  -- figure — owner revision: the verified claim pays, not km*rate.
  select * into v_row from compute_salary(v_org, v_own, '2026-07-01');
  res := res || E'\n' || format(
    'own-all-month: petrol_reference=%s (expect 120) petrol_amount=%s (expect 0, no claim submitted) bike_allowance_amount=%s (expect base=%s)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount, v_base
  );

  select * into v_row from compute_salary(v_org, v_company, '2026-07-01');
  res := res || E'\n' || format(
    'company-all-month: petrol_reference=%s (expect 0, rate is 0) petrol_amount=%s (expect 0) bike_allowance_amount=%s (expect 0)',
    v_row.petrol_reference_amount, v_row.petrol_amount, v_row.bike_allowance_amount
  );

  select * into v_row from compute_salary(v_org, v_switch, '2026-07-01');
  res := res || E'\n' || format('mid-month-switch: bike_allowance_amount=%s (expect round(%s*15/31,2)=%s)', v_row.bike_allowance_amount, v_base, round(v_base * 15 / 31, 2));

  select * into v_row from compute_salary(v_org, v_excluded, '2026-07-01');
  res := res || E'\n' || format('excluded-month: recharge_amount=%s (expect 0, not 300)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_topup, '2026-07-01');
  res := res || E'\n' || format('top-up: recharge_amount=%s (expect 250+100=350)', v_row.recharge_amount);

  select * into v_row from compute_salary(v_org, v_lowball, '2026-07-01');
  res := res || E'\n' || format('verified-lower: maintenance_amount=%s (expect 650, not 1000)', v_row.maintenance_amount);

  -- The technician with no expenses at all is entirely unaffected
  select * into v_none_after from compute_salary(v_org, v_none, '2026-07-01');
  res := res || E'\n' || format(
    'no-expenses technician unaffected: recharge=%s petrol=%s maintenance=%s bike_extra=%s, net unchanged=%s',
    v_none_after.recharge_amount, v_none_after.petrol_amount, v_none_after.maintenance_amount, v_none_after.bike_allowance_extra,
    v_none_before.net = v_none_after.net
  );

  -- Monthly report invariant: org total (these 7) equals the sum of the
  -- per-technician figures.
  select sum(recharge_amount + petrol_amount + maintenance_amount) into v_org_total
    from salaries where org_id = v_org and period = '2026-07-01' and technician_id = any(ids);
  select sum(s.recharge_amount + s.petrol_amount + s.maintenance_amount) into v_manual_sum
    from (select recharge_amount, petrol_amount, maintenance_amount from salaries where technician_id = any(ids) and period = '2026-07-01') s;
  res := res || E'\n' || format('org total reconciles with per-technician sum: %s', v_org_total = v_manual_sum);

  execute 'reset role';
  raise exception E'RESULTS%', res;
end $t$;
$t8body$;
  v_t9 text := $t9body$
-- ACL guard, CASE13 pattern (from feat/master-time-slots) -- for every
-- function created or redefined by this branch's migrations
-- (20261107100000 through 20261107100500). The pooler/test connection is
-- `postgres`, the owner of every one of these functions -- ownership does
-- not carry through a role switch (verified empirically), but relying on
-- that implicitly, inside other tests that happen to also exercise these
-- functions, is not the same as asserting it. This file asserts it
-- directly: has_function_privilege('authenticated', ..., 'execute') must be
-- true, and a real call under SET ROLE authenticated must fail (if it fails
-- at all) on business logic, never on "permission denied".
--
-- Rolled back by its own final RAISE; nothing persists.
do $t$
declare
  res text := '';
  v_sig text;
  v_call text;
  procs text[][] := array[
    ['technician_vehicle_on(uuid,uuid,date)',            $$select technician_vehicle_on(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_own_bike_days(uuid,uuid,date)',         $$select technician_own_bike_days(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_km_log_sum(uuid,uuid,date)',            $$select technician_km_log_sum(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_petrol_reference_amount(uuid,uuid,date)', $$select technician_petrol_reference_amount(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['technician_approx_distance_km(uuid,uuid,date)',    $$select technician_approx_distance_km(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['submit_expense_claim(uuid,text,numeric,text,date)', $$select submit_expense_claim(gen_random_uuid(), 'petrol', 1, 'x.jpg', current_date)$$],
    ['verify_expense_claim(uuid,numeric,text)',          $$select verify_expense_claim(gen_random_uuid(), 1, null)$$],
    ['technician_expense_claims_total(uuid,uuid,date,text)', $$select technician_expense_claims_total(gen_random_uuid(), gen_random_uuid(), current_date, 'petrol')$$],
    ['person_allowance_on(uuid,uuid,date)',              $$select person_allowance_on(gen_random_uuid(), gen_random_uuid(), current_date)$$],
    ['monthly_adjustment_top_up(uuid,uuid,date,text)',   $$select monthly_adjustment_top_up(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$],
    ['monthly_adjustment_excluded(uuid,uuid,date,text)', $$select monthly_adjustment_excluded(gen_random_uuid(), gen_random_uuid(), current_date, 'recharge')$$],
    ['compute_incentives(uuid,date)',                    $$select compute_incentives(gen_random_uuid(), current_date)$$],
    ['compute_salary(uuid,uuid,date)',                   $$select compute_salary(gen_random_uuid(), gen_random_uuid(), current_date)$$]
  ];
  v_row text[];
begin
  perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);

  foreach v_row slice 1 in array procs loop
    v_sig := v_row[1];
    v_call := v_row[2];

    if not has_function_privilege('authenticated', format('public.%s', v_sig), 'execute') then
      res := res || E'\n' || 'FAIL '||v_sig||' -- authenticated has NO execute grant';
      continue;
    end if;

    execute 'set local role authenticated';
    begin
      execute v_call;
      res := res || E'\n' || 'ok   '||v_sig||' -- granted, call unexpectedly succeeded with garbage args (still proves no permission error)';
    exception when others then
      res := res || E'\n' || case
        when sqlerrm ilike '%permission denied%' then 'FAIL '||v_sig||' -- hit permission denied: '||sqlerrm
        else 'ok   '||v_sig||' -- granted, failed on business logic not permission: '||sqlerrm
      end;
    end;
    execute 'reset role';
  end loop;

  raise exception E'RESULTS:%', res;
end
$t$;
$t9body$;
  v_m1_expected_sha256 text := '31d42bdb64e94a3323d58ec6cd5cef82e84a90ab5edfbee8c0279dface4c0bbd';
  v_m2_expected_sha256 text := '7a8f3bf2e5e3f9c8c47df819af5919a8a8265f1d76cda0f5c601135307551a01';
  v_m3_expected_sha256 text := '23b0a18657fd1ad75095ee1738809c05d439c65b5090733d6656f920c30b5756';
  v_m4_expected_sha256 text := 'f1c326ad447025e497b562c35491603d51043947a49eb457b37bcec9da0b8e23';
  v_m5_expected_sha256 text := '7ced806ea6bf7d9c5e1b8868b5a58ad7726888a43814c9805f618e0f4dd7fcf5';
  v_m6_expected_sha256 text := '2e9454db4f7fbdde4425cdc81d7255a772a54e8e2799b43cd4770c8a7634601e';
begin
  if (v_now_ist::time) < '18:00:00' then
    raise exception 'rehearsal refused: run after 18:00 IST, current IST time is %', v_now_ist::time;
  end if;
  v_actual_sha256 := encode(digest(convert_to(v_m1, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m1_expected_sha256 then
    raise exception 'rehearsal refused: migration 1 (m1) text does not match its pinned sha256 (expected %, got %)', v_m1_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 1 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);
  v_actual_sha256 := encode(digest(convert_to(v_m2, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m2_expected_sha256 then
    raise exception 'rehearsal refused: migration 2 (m2) text does not match its pinned sha256 (expected %, got %)', v_m2_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 2 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);
  v_actual_sha256 := encode(digest(convert_to(v_m3, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m3_expected_sha256 then
    raise exception 'rehearsal refused: migration 3 (m3) text does not match its pinned sha256 (expected %, got %)', v_m3_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 3 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);
  v_actual_sha256 := encode(digest(convert_to(v_m4, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m4_expected_sha256 then
    raise exception 'rehearsal refused: migration 4 (m4) text does not match its pinned sha256 (expected %, got %)', v_m4_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 4 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);
  v_actual_sha256 := encode(digest(convert_to(v_m5, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m5_expected_sha256 then
    raise exception 'rehearsal refused: migration 5 (m5) text does not match its pinned sha256 (expected %, got %)', v_m5_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 5 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);
  v_actual_sha256 := encode(digest(convert_to(v_m6, 'UTF8'), 'sha256'), 'hex');
  if v_actual_sha256 is distinct from v_m6_expected_sha256 then
    raise exception 'rehearsal refused: migration 6 (m6) text does not match its pinned sha256 (expected %, got %)', v_m6_expected_sha256, v_actual_sha256;
  end if;
  res := res || E'\n' || format('migration 6 sha256 pinned and verified via convert_to(text,''UTF8''): %s', v_actual_sha256);

  select count(*) into v_org_count from organizations where name not ilike '\_\_TEST%';
  if v_org_count <> 1 then
    raise exception 'rehearsal refused: expected exactly 1 real organisation, found %', v_org_count;
  end if;
  select id into v_org from organizations where name not ilike '\_\_TEST%' limit 1;

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_before;
  res := res || E'\n' || format('fingerprint before any migration: %s', v_fp_before);

  execute v_m1;
  execute v_m2;
  execute v_m3;
  execute v_m4;
  execute v_m5;
  execute v_m6;
  res := res || E'\n' || 'all six migrations executed, in order (20261107100000 through 20261107100500)';

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_after;
  res := res || E'\n' || format('fingerprint after all six migrations (expect identical -- DDL/function redefinition only so far, nothing here has called compute_incentives/compute_salary yet): %s -- unchanged: %s', v_fp_after, v_fp_after = v_fp_before);

  begin
    execute v_t1;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== technician_vehicles.test.sql ===' || v_test_result;

  begin
    execute v_t2;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== technician_km_log.test.sql ===' || v_test_result;

  begin
    execute v_t3;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== expense_claims.test.sql ===' || v_test_result;

  begin
    execute v_t4;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== person_allowances_and_adjustments.test.sql ===' || v_test_result;

  begin
    execute v_t5;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== compute_incentives_bike_allowance.test.sql ===' || v_test_result;

  begin
    execute v_t6;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== compute_salary_itemised_expenses.test.sql ===' || v_test_result;

  begin
    execute v_t7;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== monthly_expenses_report.test.sql ===' || v_test_result;

  begin
    execute v_t8;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== monthly_expenses_end_to_end.test.sql ===' || v_test_result;

  begin
    execute v_t9;
    v_test_result := '(completed without its own terminating RAISE -- unexpected)';
  exception when others then
    v_test_result := sqlerrm;
  end;
  res := res || E'\n\n=== acl_guard_monthly_expenses.test.sql ===' || v_test_result;

  select format('salaries=%s rows sum(net)=%s | incentives_earned=%s rows sum(amount)=%s',
      (select count(*) from salaries where org_id = v_org),
      (select coalesce(sum(net), 0) from salaries where org_id = v_org),
      (select count(*) from incentives_earned where org_id = v_org),
      (select coalesce(sum(amount), 0) from incentives_earned where org_id = v_org))
    into v_fp_after;
  res := res || E'\n\n' || format('fingerprint after every test (expect identical to the pre-migration baseline -- every test''s own terminal RAISE rolled its real-organisation mutations back via the nested BEGIN/EXCEPTION above): %s -- unchanged from before: %s', v_fp_after, v_fp_after = v_fp_before);

  raise exception E'RESULTS%', res;
end
$combo$;
