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
