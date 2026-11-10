-- Incentive audit, Finding H-03 (High) — no salary-run/approval-status state at
-- all; recompute after "Log to Accounts" is silent and untracked.
--
-- `salaries.locked_at`/`logged_expense_id` were added in 20261117100000 (needed
-- there by log_salary_to_accounts' own transaction). This migration adds the
-- ENFORCEMENT: compute_salary() now refuses to touch a locked row, and the only way
-- to unlock one is the new master-only `reopen_salary_posting(p_salary_id, p_reason)`
-- — reason required, writes an append-only audit row (`salary_reopen_audit`, a new
-- table since nothing like it exists for salaries today — the only comparable
-- pattern in this codebase is installation_incentive_credits' approved_by/voided_by
-- columns, which belong to a different table shape and couldn't hold a free-text
-- reason plus a stable list of every reopen a row has ever had), and — "in the same
-- transaction... marks the linked expense row as voided/reversed" — voids the posted
-- expense via the voided_at/voided_by/void_reason columns 20261117100000 added
-- (least-invasive choice: this codebase has no existing void convention for a plain
-- `expenses` row — only installation_incentive_credits has one, for a different
-- table — so a reversing/void flag pair, not a reversing negative-amount row
-- (`expenses.amount` has `check (amount >= 0)`, and a negative entry would also
-- leave the original overstated figure visible to any report that doesn't know to
-- net the two against each other), was the smallest change that gets it unlocked,
-- auditable, and out of every money total below. Voiding and unlocking happen
-- together: the moment the amount is no longer "logged", the row is no longer
-- "locked" either — the master is free to recompute afresh and log the corrected
-- figure.
--
-- "Least invasive" also means every report function that sums expenses.amount must
-- now exclude voided rows, or a voided salary would still show as spent after being
-- reversed — the whole point of H-03. Patched below: report_expenses_salary_by_staff
-- (drives SalaryTab/StaffSalaryTab's own "already logged" total), report_pnl,
-- report_kpi_tiles, report_expenses_year_over_year — the only functions in the
-- codebase that read public.expenses at all (confirmed by grep across
-- supabase/migrations/). Since `voided_at` is a brand-new column (every existing row
-- has it null today — confirmed live, _local_only/reports/payroll_fixes/
-- backup_before_counts.sql.out.txt), this changes no existing report figure.

-- Independent-review note (2026-10-29): salary_id/technician_id use ON DELETE
-- RESTRICT, not CASCADE -- an append-only audit trail must never silently vanish
-- because something it references got deleted (org_id keeps CASCADE, matching
-- every other table's org-scoped FK in this schema -- org deletion is a rare,
-- master-initiated operation that already cascades everything, and there is
-- nothing to restrict against). Confirmed no code path in this codebase ever
-- hard-deletes a salaries or technicians row (grepped supabase/migrations/ for
-- `delete from ... salaries` / `delete from ... technicians` -- zero hits), so
-- RESTRICT changes no existing behaviour.
create table public.salary_reopen_audit (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  salary_id uuid not null references public.salaries (id) on delete restrict,
  technician_id uuid not null references public.technicians (id) on delete restrict,
  period date not null,
  reason text not null check (char_length(btrim(reason)) > 0),
  reversed_expense_id uuid references public.expenses (id) on delete set null,
  reopened_by uuid references public.profiles (id) on delete set null,
  reopened_at timestamptz not null default now()
);

create index salary_reopen_audit_salary_id_idx on public.salary_reopen_audit (salary_id);
create index salary_reopen_audit_org_id_idx on public.salary_reopen_audit (org_id);

alter table public.salary_reopen_audit enable row level security;
revoke all on public.salary_reopen_audit from public, anon, authenticated;

-- Master-only read, matching the existing salaries/expenses SELECT policies
-- (20260701091300_rls.sql: payroll/P&L visibility is master-only, operation_admin
-- and sales_admin cannot see it at all). No INSERT/UPDATE/DELETE policy for anyone —
-- every write goes exclusively through reopen_salary_posting() below.
create policy salary_reopen_audit_select_master on public.salary_reopen_audit
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.salary_reopen_audit to authenticated;

-- compute_salary: verbatim live body (20261107100500_compute_salary_itemised_
-- expenses.sql) with ONE addition — refuse to overwrite a row already locked by
-- Log to Accounts (H-03's core ask). Nothing else in the formula changes, so an
-- unlocked recompute for the same technician+period produces the exact figure it
-- always did (proved by the rehearsal's pre/post comparison on test data).
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

revoke execute on function public.compute_salary(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.compute_salary(uuid, uuid, date) to authenticated;

-- reopen_salary_posting: master-only, reason required. Voids the linked expense
-- (least-invasive — see header) and unlocks the salaries row in one transaction,
-- writing exactly one audit row. A salary row that was never locked has nothing to
-- reopen — refused, not a silent no-op, since calling this on an unlocked row is
-- almost certainly a mistake (wrong id) rather than a legitimate retry.
create or replace function public.reopen_salary_posting(
  p_salary_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_salary record;
  v_reason text := btrim(coalesce(p_reason, ''));
begin
  if not public.is_master() then
    raise exception 'reopen_salary_posting: master role required';
  end if;
  if v_reason = '' then
    raise exception 'reopen_salary_posting: a reason is required';
  end if;

  select * into v_salary from public.salaries where id = p_salary_id;
  if v_salary is null then
    raise exception 'reopen_salary_posting: salary row % not found', p_salary_id;
  end if;
  if v_salary.org_id is distinct from public.current_org_id() then
    raise exception 'reopen_salary_posting: org mismatch';
  end if;
  if v_salary.locked_at is null then
    raise exception 'reopen_salary_posting: salary row % is not locked — nothing to reopen', p_salary_id;
  end if;

  if v_salary.logged_expense_id is not null then
    update public.expenses
      set voided_at = now(), voided_by = auth.uid(), void_reason = v_reason
      where id = v_salary.logged_expense_id and voided_at is null;
  end if;

  insert into public.salary_reopen_audit (org_id, salary_id, technician_id, period, reason, reversed_expense_id, reopened_by)
  values (v_salary.org_id, v_salary.id, v_salary.technician_id, v_salary.period, v_reason, v_salary.logged_expense_id, auth.uid());

  update public.salaries
    set locked_at = null, logged_expense_id = null
    where id = p_salary_id
    returning * into v_salary;

  return jsonb_build_object(
    'salary_id', v_salary.id,
    'locked_at', v_salary.locked_at,
    'reversed_expense_id', v_salary.logged_expense_id
  );
end;
$$;

revoke all on function public.reopen_salary_posting(uuid, text) from public, anon, authenticated;
grant execute on function public.reopen_salary_posting(uuid, text) to authenticated;

-- ── Report functions: exclude voided expense rows from every money total ──────────

create or replace function public.report_expenses_salary_by_staff(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_expenses_salary_by_staff: p_from and p_to are required';
  end if;
  if not coalesce(public.is_master(), false) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.staff_id, 'staff_name', s.name, 'total', s.total) order by s.total desc, s.name, s.staff_id), '[]'::jsonb)
  into v_result
  from (
    select e.staff_id, coalesce(p.full_name, '—') as name, sum(e.amount) as total
    from public.expenses e
    left join public.profiles p on p.id = e.staff_id
    where e.org_id = v_org and e.category = 'salary' and e.staff_id is not null and e.date >= p_from and e.date <= p_to
      and e.voided_at is null
    group by e.staff_id, p.full_name
  ) s;
  return v_result;
end;
$$;
revoke all on function public.report_expenses_salary_by_staff(date, date) from public, anon;
grant execute on function public.report_expenses_salary_by_staff(date, date) to authenticated;

create or replace function public.report_expenses_year_over_year(p_years_back integer default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_back integer := least(greatest(coalesce(p_years_back, 3), 0), 20);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_cy integer := extract(year from v_today)::integer;
  v_doy integer := extract(doy from v_today)::integer;
  v_master boolean := coalesce(public.is_master(), false);
  v_result jsonb;
begin
  with ex as (
    select e.category, e.amount, e.date, extract(year from e.date)::integer as yr, extract(doy from e.date)::integer as doy
    from public.expenses e
    where v_master and e.org_id = v_org and e.date >= make_date(v_cy - v_back, 1, 1) and e.voided_at is null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'year', y.yr,
      'full_year_total', coalesce((select sum(amount) from ex where ex.yr = y.yr), 0),
      'ytd_comparable_total', coalesce((select sum(amount) from ex where ex.yr = y.yr and ex.doy <= v_doy), 0),
      'by_category', coalesce((select jsonb_agg(jsonb_build_object('category', c.category, 'amount', c.amount) order by c.amount desc, c.category)
                               from (select category, sum(amount) as amount from ex where ex.yr = y.yr group by category) c), '[]'::jsonb)
    ) order by y.yr desc), '[]'::jsonb)
  into v_result
  from generate_series(v_cy - v_back, v_cy) y(yr);
  return v_result;
end;
$$;
revoke all on function public.report_expenses_year_over_year(integer) from public, anon;
grant execute on function public.report_expenses_year_over_year(integer) to authenticated;

create or replace function public.report_pnl(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_pnl: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with b as (
    select * from public._report_invoice_base(v_org, v_from, v_to)
  ),
  it as (
    select qty, price, discount, cost
    from public.invoice_items
    where org_id = v_org and created_at >= v_from and created_at < v_to
      and not public._invoice_is_test(invoice_id)
  ),
  gl as (
    select cost
    from public.gift_logs
    where org_id = v_org and created_at >= v_from and created_at < v_to
      and (invoice_id is null or not public._invoice_is_test(invoice_id))
  )
  select jsonb_build_object(
    'invoiced', jsonb_build_object(
      'total', (select coalesce(sum(total), 0) from b),
      'gst', (select coalesce(sum(gst), 0) from b),
      'net', (select coalesce(sum(total) - sum(gst), 0) from b)
    ),
    'collected', jsonb_build_object(
      'total', (select coalesce(sum(amount_paid), 0) from b),
      'gst', (select coalesce(round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b),
      'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)
    ),
    'expenses_by_category', case when public.is_master() then coalesce((
      select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
      from (
        select category, sum(amount) as amount
        from public.expenses
        where org_id = v_org and date >= p_from and date <= p_to and voided_at is null
        group by category
      ) e
    ), '[]'::jsonb) else '[]'::jsonb end,
    'item_profit', jsonb_build_object(
      'revenue', (select coalesce(sum(qty * price - discount), 0) from it where cost is not null),
      'cost', (select coalesce(sum(qty * cost), 0) from it where cost is not null),
      'gifts_cost', (select coalesce(sum(cost), 0) from gl where cost is not null),
      'missing_cost_count', (select count(*) from it where cost is null) + (select count(*) from gl where cost is null)
    )
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.report_pnl(date, date) from public, anon;
grant execute on function public.report_pnl(date, date) to authenticated;

create or replace function public.report_kpi_tiles(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_role text := public.current_role()::text;
  v_master boolean := (v_role = 'master');
  v_ops boolean := (v_role in ('master', 'operation_admin'));
  v_from timestamptz;
  v_to timestamptz;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_sales jsonb;
  v_service jsonb;
  v_money jsonb;
  v_funnel jsonb;
  v_ops_res jsonb;
  v_fb jsonb;
  v_cust jsonb;
  v_inv_total numeric;
  v_inv_gst numeric;
  v_coll_total numeric;
  v_coll_net numeric;
  v_exp_total numeric;
  v_won integer;
  v_leads integer;
begin
  if p_from is null or p_to is null then
    raise exception 'report_kpi_tiles: p_from and p_to are required';
  end if;
  if p_to < p_from then
    raise exception 'report_kpi_tiles: p_to must not be before p_from';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      select ii.item_type::text as item_type,
             sum(ii.qty * ii.price - ii.discount) as revenue,
             sum(ii.qty) as qty
      from public.invoice_items ii
      join b on b.invoice_id = ii.invoice_id and b.class = 'sales'
      where ii.org_id = v_org
      group by ii.item_type
    ),
    cls as (
      select class, count(*) as cnt, sum(total) as total from b group by class
    )
    select jsonb_build_object(
      'invoiced', jsonb_build_object(
        'count', (select count(*) from b),
        'total', (select coalesce(sum(total), 0) from b),
        'gst', (select coalesce(sum(gst), 0) from b),
        'net', (select coalesce(sum(total) - sum(gst), 0) from b)),
      'collected', jsonb_build_object(
        'total', (select coalesce(sum(amount_paid), 0) from b),
        'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)),
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    v_cust := public.report_customer_totals(p_from, p_to);

    v_sales := v_sales || jsonb_build_object(
      'leads', jsonb_build_object(
        'new', v_leads,
        'won', v_won,
        'lost', coalesce((v_funnel #>> '{by_status,lost}')::integer, 0),
        'won_percent', case when v_leads > 0 then round(v_won * 100.0 / v_leads, 1) end),
      'repeat_buyers', jsonb_build_object(
        'buying_customers', v_cust->'buying_customers',
        'repeat_buyers', v_cust->'repeat_buyers',
        'new_buyers', v_cust->'new_buyers',
        'repeat_rate_percent', v_cust->'repeat_rate_percent'));
  end if;

  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);
    select jsonb_build_object(
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent',
        'sla_hours', v_ops_res->'sla_hours'),
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      'amc', jsonb_build_object(
        'active', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.start_date <= v_today and c.expiry_date >= v_today),
        'renewal_window', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.status = 'due_soon' and c.expiry_date >= v_today),
        'revenue', (select coalesce(sum(b.total), 0) from public._report_invoice_base(v_org, v_from, v_to) b where b.class = 'amc'))
    ) into v_service;
  end if;

  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to and voided_at is null;

    with it as (
      select qty, price, discount, cost
      from public.invoice_items
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and not public._invoice_is_test(invoice_id)
    ),
    gl as (
      select cost
      from public.gift_logs
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and (invoice_id is null or not public._invoice_is_test(invoice_id))
    ),
    m as (
      select (select coalesce(sum(qty * price - discount), 0) from it where cost is not null) as revenue,
             (select coalesce(sum(qty * cost), 0) from it where cost is not null) as cost,
             (select coalesce(sum(cost), 0) from gl where cost is not null) as gifts,
             (select count(*) from it where cost is null) + (select count(*) from gl where cost is null) as missing
    )
    select jsonb_build_object(
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to and voided_at is null group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase' and voided_at is null)),
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      'item_margin', jsonb_build_object(
        'revenue', m.revenue, 'cost', m.cost, 'gifts_cost', m.gifts,
        'profit', m.revenue - m.cost - m.gifts,
        'margin_percent', case when m.revenue > 0 then round((m.revenue - m.cost - m.gifts) / m.revenue * 100, 1) end,
        'missing_cost_count', m.missing,
        'cost_missing', m.missing > 0)
    ) into v_money
    from m;
  end if;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'today_ist', v_today),
    'role', v_role,
    'sales', v_sales,
    'service', v_service,
    'money_out', v_money);
end;
$$;
revoke all on function public.report_kpi_tiles(date, date) from public, anon;
grant execute on function public.report_kpi_tiles(date, date) to authenticated;
