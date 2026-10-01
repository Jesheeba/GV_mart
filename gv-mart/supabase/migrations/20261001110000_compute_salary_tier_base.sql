-- compute_salary: base is now the technician's tier monthly_salary (fixed),
-- and revenue_component takes over what base used to hold
-- (technician_attributed_revenue, calculation unchanged — still no paid
-- filter, deliberately: changing it would alter current pay). net formula is
-- unchanged: base + revenue_component - late_deduction + incentives.
--
-- Tier lookup is fresh on every run via technicians.tier_id; a null tier_id
-- falls back to the org's rank=1 tier, and no tier at all gives base 0.
-- salaries.base freezes the number per period on write, so later tier edits
-- or promotions never touch past rows, and there is no proration: a period
-- already computed stays as-is until recomputed.
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

  insert into public.salaries (org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net)
  values (
    p_org_id, p_technician_id, v_period, v_base, v_revenue, v_late_deduction, v_incentives,
    v_base + v_revenue - v_late_deduction + v_incentives
  )
  on conflict (technician_id, period) do update set
    base = excluded.base,
    revenue_component = excluded.revenue_component,
    late_deduction = excluded.late_deduction,
    incentives = excluded.incentives,
    net = excluded.net
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;
revoke execute on function public.compute_salary(uuid, uuid, date) from anon;
