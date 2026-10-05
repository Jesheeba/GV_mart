-- All incentive types now use Asia/Kolkata calendar months (follow-up to
-- 20261006120000, which did installations only): service income, sales income,
-- finder credit (helpers) and the review count inside compute_incentives. Because
-- compute_salary derives revenue_component from technician_attributed_revenue and
-- sums incentives_earned by period, salary and incentives move together.
--
-- Generated from each function's LIVE definition; the ONLY rewrites are the month
-- windows on timestamptz columns (`>= date_trunc('month', p)` / `< ... + 1 month`).
-- Left alone: technician_late_hours / compute_salary / reward_candidates compare
-- plain date columns, so there is no timezone boundary to move.

-- compute_incentives(p_org_id uuid, p_period date)
CREATE OR REPLACE FUNCTION public.compute_incentives(p_org_id uuid, p_period date)
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

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;

-- technician_attributed_revenue(p_org_id uuid, p_technician_id uuid, p_period date)
CREATE OR REPLACE FUNCTION public.technician_attributed_revenue(p_org_id uuid, p_technician_id uuid, p_period date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(v.service_charge), 0)::numeric(12, 2)
  from public.service_visits v
  where v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and v.timer_end is not null
    and v.timer_end >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and v.timer_end < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_attributed_sales(p_org_id uuid, p_technician_id uuid, p_period date)
CREATE OR REPLACE FUNCTION public.technician_attributed_sales(p_org_id uuid, p_technician_id uuid, p_period date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(i.subtotal), 0)::numeric(12, 2)
  from public.invoices i
  join public.technicians t on t.profile_id = i.sold_by
  where i.org_id = p_org_id
    and t.id = p_technician_id
    and t.org_id = p_org_id
    and i.created_at >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and i.created_at < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_finder_conversions(p_org_id uuid, p_technician_id uuid, p_period date)
CREATE OR REPLACE FUNCTION public.technician_finder_conversions(p_org_id uuid, p_technician_id uuid, p_period date)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select count(distinct v.ticket_id)::integer
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  join public.leads l on l.id = st.lead_id
  where v.org_id = p_org_id
    and st.org_id = p_org_id
    and st.lead_id is not null
    and l.owner_id = p_technician_id
    and st.status = 'completed'
    and v.timer_end is not null
    and v.timer_end >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and v.timer_end < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;
