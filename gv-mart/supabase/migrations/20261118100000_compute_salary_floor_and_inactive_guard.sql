-- Connection-map follow-up findings F-01 (High) and F-02 (Medium).
--
-- F-01: compute_salary() could produce a NEGATIVE net salary with no floor and
-- no visible record of the shortfall -- confirmed live on a real technician
-- (see DECISIONS.md: the connection-map audit's own leaked preview produced a
-- real net of -39.30 for a technician with no base tier and a real late-hour
-- penalty). Fix: `net` is now floored at zero (`greatest(v_raw_net, 0)`), and
-- the amount the floor absorbed is recorded, never silently dropped, in a new
-- `salaries.shortfall_amount` column (0 whenever nothing was floored). The HR
-- Salary screen surfaces this (src/app/admin/hr/SalaryTab.tsx) as a visible
-- warning line, not a hidden field -- "do not just hide it" per the task.
--
-- Does not change any CURRENTLY-POSITIVE result: when the raw formula is >= 0,
-- `greatest(raw, 0) = raw` and `shortfall_amount = 0` -- byte-identical to
-- today's behaviour. Only a formerly-negative result changes (from a negative
-- number nobody could act on, to 0 plus a visible shortfall figure). Proved on
-- test data in the rehearsal for this migration (both a positive-net
-- technician, unaffected, and a negative-net technician, floored+recorded, in
-- the same run).
--
-- F-02: compute_salary() had no `is_active` guard at all -- only the UI's
-- `listActiveTechnicians` (is_active = true) kept it from ever being called
-- for a deactivated technician; a direct RPC call for one's still-unlocked
-- period computed happily. compute_incentives() already gates its technician
-- loop on `is_active` (`20261016110000_test_customer_flag.sql:1008-1060`,
-- `where org_id = p_org_id and is_active`); this mirrors that exact guard for
-- the single-technician case compute_salary actually is, folded into the
-- existing "technician not found" check (same raised-exception shape, now
-- also true for "found but inactive").

alter table public.salaries
  add column if not exists shortfall_amount numeric(12, 2) not null default 0 check (shortfall_amount >= 0);

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
  v_locked_at timestamptz;
  v_raw_net numeric(12, 2);
  v_net numeric(12, 2);
  v_shortfall numeric(12, 2);
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
  -- F-02: "not found" and "found but inactive" both refuse, same as
  -- compute_incentives' loop-level is_active filter.
  if not exists (select 1 from public.technicians where id = p_technician_id and org_id = p_org_id and is_active) then
    raise exception 'compute_salary: technician % not found or inactive in org %', p_technician_id, p_org_id;
  end if;

  -- Finding H-03: a salary already posted to Accounts ("logged") is locked —
  -- recompute is refused until reopen_salary_posting() clears it (voiding the
  -- posted expense in the same move).
  select locked_at into v_locked_at
  from public.salaries
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  if v_locked_at is not null then
    raise exception 'compute_salary: salary for technician % period % is locked (logged to Accounts on %) — use reopen_salary_posting first',
      p_technician_id, v_period, v_locked_at::date;
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

  v_km := public.technician_km_log_sum(p_org_id, p_technician_id, v_period);
  select coalesce(petrol_rate_per_km, 0) into v_rate
  from public.technician_vehicle_on(p_org_id, p_technician_id, (v_period + interval '1 month' - interval '1 day')::date);
  v_rate := coalesce(v_rate, 0);
  v_petrol_reference := public.technician_petrol_reference_amount(p_org_id, p_technician_id, v_period);
  v_petrol := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'petrol');

  v_maintenance := public.technician_expense_claims_total(p_org_id, p_technician_id, v_period, 'maintenance');

  select * into v_bike_row from public.incentives_earned
    where technician_id = p_technician_id and period = v_period and is_bike_allowance;
  select own_bike_allowance_base into v_bike_base from public.settings where org_id = p_org_id;
  v_bike_base := coalesce(v_bike_base, 0);
  v_bike_extra := public.monthly_adjustment_top_up(p_org_id, v_profile_id, v_period, 'bike_allowance');
  select reason into v_bike_reason from public.monthly_adjustments
    where org_id = p_org_id and profile_id = v_profile_id and period = v_period and adjustment_target = 'bike_allowance'
    order by created_at desc limit 1;
  v_bike_amount := coalesce(v_bike_row.amount, 0);

  -- F-01: floor at zero, record whatever the floor absorbed. Byte-identical
  -- to the old formula whenever the raw result is already >= 0.
  v_raw_net := v_base + v_revenue - v_late_deduction + v_incentives + v_recharge + v_petrol + v_maintenance;
  v_net := greatest(v_raw_net, 0);
  v_shortfall := greatest(-v_raw_net, 0);

  insert into public.salaries (
    org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net, shortfall_amount,
    recharge_amount, recharge_reason, petrol_km, petrol_rate, petrol_reference_amount, petrol_amount,
    maintenance_amount, bike_allowance_base, bike_allowance_extra, bike_allowance_reason, bike_allowance_amount
  )
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives, v_net, v_shortfall,
    v_recharge, v_recharge_reason, v_km, v_rate, v_petrol_reference, v_petrol,
    v_maintenance, v_bike_base, v_bike_extra, v_bike_reason, v_bike_amount
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net,
    shortfall_amount = excluded.shortfall_amount,
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

revoke execute on function public.compute_salary(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;
