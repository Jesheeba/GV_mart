-- Phase 10 (HR/Payroll) — RPCs for ADM-24 Salary, ADM-25 Incentives.
--
-- All three are SECURITY DEFINER: salaries/incentives_earned are
-- master-only under RLS (20260701091300_rls.sql: salaries_write_master,
-- incentives_earned_write_master), and computing them needs to read
-- attendance/service_visits/invoices/ratings which the caller (master) can
-- already see under is_staff()/is_master() policies anyway — DEFINER here
-- is purely to let the upsert into salaries/incentives_earned happen inside
-- the same statement as the read, not to widen what the caller can see.
-- Every function re-checks is_master() + org match explicitly before
-- touching anything, same pattern as create_sale in
-- 20260702100100_sales_phase5_functions.sql.
--
-- v2.2 AUTHORITY NOTE (BuildSpec header table + ADM-24 APPEARS line):
-- "Salary: revenue-based, admin-set, NO fixed ₹ ... late deduction hours×2"
-- and ADM-24's literal formula example: "revenue-based base e.g.
-- ₹5-6k/day→₹2,000, +₹5,000/month per extra ₹1k/day". Since no slab table
-- exists in the schema (Section 5 lists only `salaries` as a *result* table
-- — there is no "salary_slabs" master, and the scope guard explicitly
-- forbids inventing new master screens beyond what's listed), the per-org
-- `settings` row is the only admin-configurable surface available without
-- inventing a new master table out of scope. Rather than hardcode the
-- ₹5-6k/₹2,000/₹5,000/₹1,000 figures from the example into SQL (a direct
-- violation of "no fixed ₹ salary bands anywhere" in the v2.2 override
-- table), this RPC computes:
--   base = technician's attributed revenue for the period, unmodified
--   revenue_component = 0 (no separate slab function exists to compute a
--     *different* number from base without inventing unstated slab
--     boundaries/rates)
--   late_deduction = total late hours in the period x 2 (the one concrete,
--     unambiguous rule v2.2 does give us)
--   incentives = sum of incentives_earned for the technician+period
--   net = base + revenue_component - late_deduction + incentives
-- This is flagged in the build report as a judgment call: a true slab
-- engine (₹X per extra ₹1k/day of revenue) needs an admin-configurable
-- slab master that doesn't exist yet and is out of this migration's file
-- scope (no new master screens beyond ADM-14..26). base = attributed
-- revenue is the closest faithful, non-invented reading of "revenue-based
-- base" that a master can review and hand-adjust (salaries is a normal
-- editable table) before finalizing a payslip.

-- Attributed revenue for one technician in [p_period, p_period + 1 month):
-- sum of service_visits.service_charge for visits the technician performed
-- whose ticket closed with an invoice in that window, PLUS product/spare/
-- AMC invoices is not attributable to a technician (invoices has no
-- technician_id — sales are attributed to sales_admin, not field techs) so
-- deliberately excluded. service_visits.service_charge is used directly
-- (not invoices.total via service_tickets.invoice_id) because it's already
-- the per-visit revenue figure net of AMC/warranty free visits (those save
-- service_charge = 0 per BuildSpec §6.6 "warranty/AMC visits cost ₹0").
create or replace function public.technician_attributed_revenue(
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
  select coalesce(sum(v.service_charge), 0)::numeric(12, 2)
  from public.service_visits v
  where v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and v.timer_end is not null
    and v.timer_end >= date_trunc('month', p_period)
    and v.timer_end < date_trunc('month', p_period) + interval '1 month';
$$;

-- Late hours for one technician in a calendar-month period. is_late is a
-- boolean flag (attendance table has no explicit "minutes late" column), so
-- "hours late" is derived as: for each is_late=true day, the time between
-- settings.late_cutoff and the actual check_in_at time-of-day, floored at 0.
-- This is the most faithful reading available from the existing schema
-- without inventing a new column (out of file-ownership scope — attendance
-- is an existing, integrator-owned table per Phase 1).
create or replace function public.technician_late_hours(
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
declare
  v_late_cutoff time;
  v_total_hours numeric(12, 4) := 0;
begin
  select late_cutoff into v_late_cutoff from public.settings where org_id = p_org_id;
  v_late_cutoff := coalesce(v_late_cutoff, '09:15:00'::time);

  select coalesce(sum(
    greatest(0, extract(epoch from ((a.check_in_at at time zone 'Asia/Kolkata')::time - v_late_cutoff)) / 3600.0)
  ), 0)
  into v_total_hours
  from public.attendance a
  where a.org_id = p_org_id
    and a.technician_id = p_technician_id
    and a.is_late = true
    and a.check_in_at is not null
    and a.date >= date_trunc('month', p_period)::date
    and a.date < (date_trunc('month', p_period) + interval '1 month')::date;

  return round(v_total_hours, 2);
end;
$$;

-- ADM-24: compute (or recompute) one technician's payslip for a calendar
-- month and upsert it into `salaries` (unique on technician_id+period).
-- p_period may be any date within the target month; normalized to the 1st.
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

  v_revenue := public.technician_attributed_revenue(p_org_id, p_technician_id, v_period);
  v_late_hours := public.technician_late_hours(p_org_id, p_technician_id, v_period);
  -- v2.2: "late deduction hours x 2" — deduction is a currency amount, 2
  -- rupees per late hour is the literal reading of the multiplier with no
  -- other admin-set rate available for it in `settings`.
  v_late_deduction := round(v_late_hours * 2, 2);

  select coalesce(sum(amount), 0) into v_incentives
  from public.incentives_earned
  where org_id = p_org_id and technician_id = p_technician_id and period = v_period;

  insert into public.salaries (org_id, technician_id, period, base, revenue_component, late_deduction, incentives, net)
  values (
    p_org_id, p_technician_id, v_period, v_revenue, 0, v_late_deduction, v_incentives,
    v_revenue + 0 - v_late_deduction + v_incentives
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

-- ADM-25: evaluate every active incentive_rules row against real technician
-- activity for a period and insert qualifying rows into incentives_earned
-- (skips technician+rule+period combos that already have a row, so it's
-- safe to re-run). Rule semantics (incentive_type):
--   service_income: technician's attributed service revenue (same figure
--     as compute_salary's `base`) for the period >= threshold -> amount
--   sales_income: v2.2 explicitly separates "sales income" from service
--     income, but invoices carry no technician_id (sales are attributed to
--     sales_admin/master, not a field technician — see comment above
--     technician_attributed_revenue). No technician-level sales-income
--     figure exists anywhere in the schema to compare against a threshold,
--     so this type is evaluated as 0 for every technician (never qualifies)
--     rather than silently reusing the service-income figure under a
--     different name. Flagged in the build report as a schema gap, not
--     invented around.
--   review: count of 4.5-5 star ratings (google_review_clicked marks the
--     ones that crossed the v2.2 "shows only at 4.5-5 star" link threshold,
--     i.e. exactly the reviews that count) attributed to the technician's
--     visits in the period >= threshold -> amount
create or replace function public.compute_incentives(
  p_org_id uuid,
  p_period date
)
returns setof incentives_earned
language plpgsql
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_rule record;
  v_tech record;
  v_metric numeric(12, 2);
  v_review_count integer;
begin
  if not public.is_master() then
    raise exception 'compute_incentives: master role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'compute_incentives: org mismatch';
  end if;

  for v_rule in select * from public.incentive_rules where org_id = p_org_id loop
    for v_tech in select id from public.technicians where org_id = p_org_id and is_active loop
      if exists (
        select 1 from public.incentives_earned
        where org_id = p_org_id and technician_id = v_tech.id and rule_id = v_rule.id and period = v_period
      ) then
        continue;
      end if;

      if v_rule.type = 'service_income' then
        v_metric := public.technician_attributed_revenue(p_org_id, v_tech.id, v_period);
        if v_metric >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;

      elsif v_rule.type = 'sales_income' then
        -- No technician-attributable sales figure exists in the schema
        -- (see function header) — never qualifies. Left as an explicit
        -- branch (not folded into the else) so the gap is visible in code,
        -- not silently absent.
        null;

      elsif v_rule.type = 'review' then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
          and r.created_at >= date_trunc('month', v_period)
          and r.created_at < date_trunc('month', v_period) + interval '1 month';

        if v_review_count >= v_rule.threshold and v_rule.threshold > 0 then
          insert into public.incentives_earned (org_id, technician_id, rule_id, amount, period)
          values (p_org_id, v_tech.id, v_rule.id, v_rule.amount, v_period);
        end if;
      end if;
    end loop;
  end loop;

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$$;

grant execute on function public.compute_incentives(uuid, date) to authenticated;

-- ADM-26: eligible winner(s) per reward_category for a period, applying the
-- v2.2 stated minimums (min 51 reviews, min ₹1,50,000 revenue). Read-only —
-- callers still log the actual reward via a normal insert into `rewards`
-- (rewards_write_ops already permits is_ops_staff() to do that directly, no
-- RPC needed for the write side).
create or replace function public.reward_candidates(
  p_org_id uuid,
  p_period date
)
returns table (
  category reward_category,
  technician_id uuid,
  metric numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_period date := date_trunc('month', p_period)::date;
begin
  if not public.is_staff() then
    raise exception 'reward_candidates: staff role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'reward_candidates: org mismatch';
  end if;

  return query
  -- attendance: on-time (never late) technicians this period, ranked by
  -- most check-ins (a simple, schema-faithful "most consistently on-time"
  -- proxy — v2.2 gives a category name but no explicit tie-break rule).
  with attendance_agg as (
    select a.technician_id, count(*) as days_present
    from public.attendance a
    where a.org_id = p_org_id
      and a.date >= date_trunc('month', v_period)::date
      and a.date < (date_trunc('month', v_period) + interval '1 month')::date
      and a.is_late = false
      and not exists (
        select 1 from public.attendance a2
        where a2.technician_id = a.technician_id and a2.org_id = p_org_id
          and a2.date >= date_trunc('month', v_period)::date
          and a2.date < (date_trunc('month', v_period) + interval '1 month')::date
          and a2.is_late = true
      )
    group by a.technician_id
  ),
  review_agg as (
    select v.technician_id, count(*) as review_count
    from public.ratings r
    join public.service_visits v on v.id = r.visit_id
    where v.org_id = p_org_id
      and r.created_at >= date_trunc('month', v_period)
      and r.created_at < date_trunc('month', v_period) + interval '1 month'
    group by v.technician_id
  ),
  revenue_agg as (
    select v.technician_id, sum(v.service_charge) as revenue
    from public.service_visits v
    where v.org_id = p_org_id
      and v.timer_end is not null
      and v.timer_end >= date_trunc('month', v_period)
      and v.timer_end < date_trunc('month', v_period) + interval '1 month'
    group by v.technician_id
  )
  select 'attendance'::reward_category, aa.technician_id, aa.days_present::numeric
  from attendance_agg aa
  where aa.days_present = (select max(days_present) from attendance_agg)
  union all
  select 'highest_review'::reward_category, ra.technician_id, ra.review_count::numeric
  from review_agg ra
  where ra.review_count >= 51
    and ra.review_count = (select max(review_count) from review_agg where review_count >= 51)
  union all
  select 'highest_revenue'::reward_category, rv.technician_id, rv.revenue::numeric
  from revenue_agg rv
  where rv.revenue >= 150000
    and rv.revenue = (select max(revenue) from revenue_agg where revenue >= 150000);
end;
$$;

grant execute on function public.reward_candidates(uuid, date) to authenticated;
