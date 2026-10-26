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
