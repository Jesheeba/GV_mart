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
-- ACL audit (this review): insert_own previously checked only
-- technician_id = current_technician_id(), with NO org_id check at all --
-- a technician could insert a row for themself tagged with ANY org_id,
-- not just their own. insert_staff checked org_id = current_org_id() but
-- never verified the technician_id it was inserting for actually belongs
-- to that org -- an ops staff member could log km against a technician
-- from a different organisation entirely. Both now also require the row's
-- org_id to genuinely match the technician: insert_own via current_org_id()
-- (the technician's own org, resolved server-side, same as every other
-- self-scoped check in this codebase), insert_staff via an explicit
-- existence check against technicians.
create policy technician_km_log_insert_own on public.technician_km_log
  for insert with check (
    technician_id = public.current_technician_id()
    and org_id = public.current_org_id()
  );
-- NOTE on the fix below: `t.org_id = org_id` (unqualified) inside this
-- subquery would be a TAUTOLOGY, not a real check -- technicians also has
-- a column named org_id, so Postgres resolves the unqualified reference
-- to the subquery's OWN table (t.org_id), giving `t.org_id = t.org_id`
-- (always true) instead of comparing against the outer row's org_id. The
-- outer table name is qualified explicitly to force the comparison
-- against the actual INSERTed row, not the subquery's own alias.
create policy technician_km_log_insert_staff on public.technician_km_log
  for insert with check (
    org_id = public.current_org_id()
    and public.is_ops_staff()
    and exists (
      select 1 from public.technicians t
      where t.id = technician_km_log.technician_id
        and t.org_id = technician_km_log.org_id
    )
  );
-- Deliberately no update/delete policy at all (for any role) — append-only.

-- Table-level grants: both the technician's own screen and the admin
-- KmLogTab read and insert this table directly, so authenticated needs
-- select/insert and nothing more -- no update/delete anywhere in the
-- service layer (append-only by design), matching the absence of any
-- update/delete policy above.
revoke all on table public.technician_km_log from public, anon, authenticated;
grant select, insert on table public.technician_km_log to authenticated;

-- ACL audit (this migration's three read functions, all genuinely called
-- directly from the frontend as RPCs, confirmed against
-- src/services/monthlyExpenses.ts and every component that imports its
-- hooks): the first version of each had NO caller/org check at all — any
-- authenticated user could pass an arbitrary org_id/technician_id and read
-- another organisation's or another technician's monthly figures. All
-- three are rewritten here as plpgsql with an explicit guard that RAISEs
-- (loud refusal, matching submit_expense_claim/verify_expense_claim's own
-- convention) rather than silently filtering to an empty/zero result. The
-- guard is symmetric across all three: master/operation_admin may query
-- any technician in their org; a technician may query only themself.

-- Monthly sum of the manual log — informational total shown on the salary
-- breakdown and the verification queue (§1.5). Payment for petrol is the
-- admin's verified claim amount (Unit 3/6), not this figure. Called
-- directly by both the admin KmLogTab (any technician) and the
-- technician's own ExpensesPage (self) — see useKmLogMonthlySum.
create or replace function public.technician_km_log_sum(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_km_log_sum: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_km_log_sum: access denied';
  end if;

  return coalesce((
    select sum(km)
    from public.technician_km_log
    where org_id = p_org_id
      and technician_id = p_technician_id
      and entry_date >= date_trunc('month', p_period)::date
      and entry_date < (date_trunc('month', p_period)::date + interval '1 month')
  ), 0);
end;
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
-- for ownership. Called directly by the admin VerificationQueueTab for the
-- claim's own technician — see usePetrolReferenceAmount.
create or replace function public.technician_petrol_reference_amount(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_petrol_reference_amount: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_petrol_reference_amount: access denied';
  end if;

  return coalesce((
    select sum(l.km * coalesce(v.petrol_rate_per_km, 0))
    from public.technician_km_log l
    left join public.technician_vehicles v
      on v.org_id = p_org_id
      and v.technician_id = p_technician_id
      and v.effective_from <= l.entry_date
      and coalesce(v.effective_to, 'infinity'::date) >= l.entry_date
    where l.org_id = p_org_id
      and l.technician_id = p_technician_id
      and l.entry_date >= date_trunc('month', p_period)::date
      and l.entry_date < (date_trunc('month', p_period)::date + interval '1 month')
  ), 0);
end;
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
-- source of payment. Called directly by the admin KmLogTab for the
-- selected technician — see useApproxDistanceKm.
create or replace function public.technician_approx_distance_km(
  p_org_id uuid,
  p_technician_id uuid,
  p_period date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'technician_approx_distance_km: org mismatch';
  end if;
  if not (public.is_ops_staff() or p_technician_id = public.current_technician_id()) then
    raise exception 'technician_approx_distance_km: access denied';
  end if;

  return coalesce((
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
    select round(sum(
      2 * 6371 * asin(least(1, sqrt(
        sin(radians(lat - prev_lat) / 2) ^ 2
        + cos(radians(prev_lat)) * cos(radians(lat)) * sin(radians(lng - prev_lng) / 2) ^ 2
      )))
    )::numeric, 1)
    from pings
    where prev_lat is not null and prev_lng is not null
  ), 0);
end;
$$;

grant execute on function public.technician_approx_distance_km(uuid, uuid, date) to authenticated;
revoke execute on function public.technician_approx_distance_km(uuid, uuid, date) from public, anon;
