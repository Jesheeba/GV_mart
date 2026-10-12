-- Rollback for 20261016150000_review_incentives_switch.sql (restores the live bodies as of 20261016120000).
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

      -- A rule set to â‚¹0 pays nothing: no zero-amount rows.
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

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;
create or replace function public.technician_kpi_summary(p_org_id uuid, p_technician_id uuid)
 RETURNS TABLE(avg_call_value numeric, total_referrals integer, total_reviews integer, total_installations integer, completed_visit_count integer, review_claim_rate_percent numeric, flagged boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_threshold numeric;
  v_min_visits integer;
  v_visit_count integer;
  v_review_count integer;
  v_install_count integer;
begin
  if p_org_id is distinct from public.current_org_id() or not public.is_staff() then
    raise exception 'technician_kpi_summary: access denied';
  end if;

  select review_flag_threshold_percent, review_flag_min_visits
    into v_threshold, v_min_visits
    from public.settings where org_id = p_org_id;
  v_threshold := coalesce(v_threshold, 65);
  v_min_visits := coalesce(v_min_visits, 10);

  select count(*) into v_visit_count
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  where v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and st.status = 'completed'
        and not public.is_test_customer(st.customer_id)
    and v.timer_end is not null;

  select count(*) into v_review_count
  from public.customer_members cm
  where cm.org_id = p_org_id
    and cm.google_review_technician_id = p_technician_id
    and cm.google_review_photo_url is not null
    and not public.is_test_customer(cm.customer_id);

  select coalesce(sum(il.qty), 0) into v_install_count
  from public.installations_logged il
  where il.org_id = p_org_id
    and il.technician_id = p_technician_id
    and not public._visit_is_test(il.visit_id);

  return query
  select
    (
      select avg(v.service_charge)
      from public.service_visits v
      join public.service_tickets st on st.id = v.ticket_id
      join public.invoices i on i.id = st.invoice_id
      where v.org_id = p_org_id
        and v.technician_id = p_technician_id
        and st.status = 'completed'
        and not public.is_test_customer(st.customer_id)
        and v.timer_end is not null
        and i.org_id = p_org_id
        and i.payment_status = 'paid'
    ),
    (
      select count(distinct v.ticket_id)::integer
      from public.service_visits v
      join public.service_tickets st on st.id = v.ticket_id
      join public.leads l on l.id = st.lead_id
      where v.org_id = p_org_id
        and st.lead_id is not null
        and l.owner_id = p_technician_id
        and st.status = 'completed'
        and not public.is_test_customer(st.customer_id)
        and v.timer_end is not null
    ),
    v_review_count,
    v_install_count,
    v_visit_count,
    case when v_visit_count > 0 then round(v_review_count::numeric / v_visit_count * 100, 1) else 0 end,
    v_visit_count >= v_min_visits
      and v_visit_count > 0
      and (v_review_count::numeric / v_visit_count * 100) >= v_threshold;
end;
$function$;
alter table public.settings drop column if exists review_incentives_enabled;
notify pgrst, 'reload schema';
