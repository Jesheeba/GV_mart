-- Monthly Expenses spec, Unit 5 — own-bike allowance flows into
-- compute_incentives (§1.6/§1.9). This is the ONLY item from this feature
-- that touches incentives; the other three (recharge, petrol, maintenance)
-- are reimbursements and only ever appear in compute_salary (Unit 6).
--
-- `incentives_earned` already has a 2-way XOR between `rule_id` and
-- `installation_rate_id` as its "exactly one source" guard
-- (20261006110000_installation_incentive_rates.sql). This widens it to a
-- 3-way guard and adds the new source as a boolean flag rather than a new
-- nullable FK, since a bike-allowance row has no row of its own to point
-- at (unlike a rule or a rate) — it's resolved fresh from
-- technician_vehicles + settings + monthly_adjustments every run, same as
-- the per-unit installation block already does for its own source.

alter table public.incentives_earned
  add column is_bike_allowance boolean not null default false;

alter table public.incentives_earned drop constraint incentives_earned_one_source;

alter table public.incentives_earned
  add constraint incentives_earned_one_source check (
    (case when rule_id is not null then 1 else 0 end)
    + (case when installation_rate_id is not null then 1 else 0 end)
    + (case when is_bike_allowance then 1 else 0 end) = 1
  );

create unique index incentives_earned_bike_allowance_unique_idx
  on public.incentives_earned (technician_id, period)
  where is_bike_allowance;

-- compute_incentives: verbatim live body (20261007100000_incentive_rules_
-- active_flag.sql) up to and including the per-unit installation-rate block,
-- with one new block appended just before the final `return query` —
-- marked below. Nothing above that marker changed.
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
  v_rate record;
  v_metric numeric(12, 2);
  v_review_count integer;
  v_amount numeric(12, 2);
  v_existing_id uuid;
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

      elsif v_rule.type = 'review' then
        select count(*) into v_review_count
        from public.ratings r
        join public.service_visits v on v.id = r.visit_id
        where v.org_id = p_org_id
          and v.technician_id = v_tech.id
          and r.google_review_clicked = true
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

  -- ── Unit 5: own-bike allowance (new block) ──────────────────────────────
  -- Pro-rated by days-in-month on an own bike (technician_own_bike_days,
  -- Unit 1); a company-bike technician or one with no vehicle row at all
  -- gets 0 own-days and so pays 0 — "every existing component of the
  -- incentive total is unchanged" holds because this block only ever
  -- INSERTS a new is_bike_allowance row or UPDATEs one it already owns; it
  -- never touches a rule_id/installation_rate_id row.
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
$$;

grant execute on function public.compute_incentives(uuid, date) to authenticated;
