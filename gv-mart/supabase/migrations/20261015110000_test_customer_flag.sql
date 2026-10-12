-- Test-customer flag (2026-10-15) — batch-2 item 5.
--
-- ONE real-organisation customer ("jeshee test trigger") is kept for end-to-end tests. It must not show up in any report,
-- KPI, count, incentive or round-robin pick, but every normal flow (sale, ticket, AMC, WhatsApp) keeps working for it.
--   * customers.is_test  : the flag. Only the master (or a service-role/SQL session) may set or clear it.
--   * leads.is_test      : kept in step automatically — a lead is test when its customer is test OR its mobile equals a test
--                          customer's mobile (same organisation). This is how "the lead that shares the number" is flagged.
--   * helpers            : is_test_customer(customer), _ticket_is_test(ticket), _visit_is_test(visit), _invoice_is_test(invoice).
--   * every function that aggregates customer-linked data (reports, KPIs, pay, lead counts/queues/digest, round robin) is
--     replaced from its LIVE body with ONE added predicate each. The list is mirrored in supabase/test-customer-guard.manifest.json,
--     which a CI test checks, so a new aggregating function cannot ship without an explicit decision.
-- Suppliers are untouched (a supplier row sharing the number is a separate record).

alter table public.customers add column is_test boolean not null default false;
create index customers_is_test_idx on public.customers (org_id) where is_test;
alter table public.leads add column is_test boolean not null default false;
create index leads_is_test_idx on public.leads (org_id) where is_test;

create function public.is_test_customer(p_customer_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select c.is_test from public.customers c where c.id = p_customer_id), false)
$$;
create function public._ticket_is_test(p_ticket_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.service_tickets t join public.customers c on c.id = t.customer_id where t.id = p_ticket_id and c.is_test)
$$;
create function public._visit_is_test(p_visit_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.service_visits v
    join public.service_tickets t on t.id = v.ticket_id
    join public.customers c on c.id = t.customer_id
    where v.id = p_visit_id and c.is_test)
$$;
create function public._invoice_is_test(p_invoice_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.invoices i join public.customers c on c.id = i.customer_id where i.id = p_invoice_id and c.is_test)
$$;
revoke execute on function public.is_test_customer(uuid), public._ticket_is_test(uuid), public._visit_is_test(uuid), public._invoice_is_test(uuid)
  from public, anon, authenticated;
grant execute on function public.is_test_customer(uuid), public._ticket_is_test(uuid), public._visit_is_test(uuid), public._invoice_is_test(uuid) to service_role;

-- only the master (or a trusted SQL/service session) can flag or unflag a customer
create function public._trg_customer_is_test_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (tg_op = 'INSERT' and new.is_test) or (tg_op = 'UPDATE' and new.is_test is distinct from old.is_test) then
    if auth.uid() is not null and not public.is_master() then
      raise exception 'only the master can flag or unflag a test customer';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public._trg_customer_is_test_guard() from public, anon, authenticated;
create trigger customers_is_test_guard before insert or update of is_test on public.customers
  for each row execute function public._trg_customer_is_test_guard();

-- digits only, last 10 (matches how Indian mobiles are compared elsewhere)
create function public._mobile_key(p_mobile text)
returns text language sql immutable as $$ select nullif(right(regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), 10), '') $$;
revoke execute on function public._mobile_key(text) from public, anon;

create function public._lead_is_test_value(p_org uuid, p_customer uuid, p_mobile text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.is_test_customer(p_customer), false)
      or (public._mobile_key(p_mobile) is not null and exists (
            select 1 from public.customers c
            where c.org_id = p_org and c.is_test and public._mobile_key(c.mobile) = public._mobile_key(p_mobile)))
$$;
revoke execute on function public._lead_is_test_value(uuid, uuid, text) from public, anon, authenticated;

-- 'aa_' so it fires BEFORE leads_auto_assign (the round-robin trigger reads new.is_test)
create function public._trg_lead_is_test_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.is_test := public._lead_is_test_value(new.org_id, new.customer_id, new.mobile);
  return new;
end;
$$;
revoke execute on function public._trg_lead_is_test_sync() from public, anon, authenticated;
create trigger aa_leads_is_test_sync before insert or update of customer_id, mobile on public.leads
  for each row execute function public._trg_lead_is_test_sync();

-- when a customer is flagged/unflagged (or their mobile changes) re-evaluate that customer's leads and any lead with the same number
create function public._trg_customer_is_test_cascade()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.leads l
  set is_test = public._lead_is_test_value(l.org_id, l.customer_id, l.mobile)
  where l.org_id = new.org_id
    and (l.customer_id = new.id
         or (public._mobile_key(new.mobile) is not null and public._mobile_key(l.mobile) = public._mobile_key(new.mobile)))
    and l.is_test is distinct from public._lead_is_test_value(l.org_id, l.customer_id, l.mobile);
  return null;
end;
$$;
revoke execute on function public._trg_customer_is_test_cascade() from public, anon, authenticated;
create trigger customers_is_test_cascade after insert or update of is_test, mobile on public.customers
  for each row execute function public._trg_customer_is_test_cascade();


-- _report_invoice_base
create or replace function public._report_invoice_base(p_org uuid, p_from_ts timestamp with time zone, p_to_ts timestamp with time zone)
 RETURNS TABLE(invoice_id uuid, class text, invoice_type invoice_type, total numeric, gst numeric, amount_paid numeric, customer_id uuid, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    i.id,
    case i.type
      when 'product' then 'sales'
      when 'amc' then 'amc'
      when 'rent' then 'rental'
      else case
        when exists (
          select 1
          from public.service_tickets t
          where t.org_id = i.org_id
            and t.invoice_id = i.id
            and exists (select 1 from public.service_visits v where v.ticket_id = t.id and v.org_id = t.org_id)
        ) then 'service'
        else 'sales'
      end
    end,
    i.type,
    coalesce(i.total, 0),
    coalesce(i.gst, 0),
    coalesce(i.amount_paid, 0),
    i.customer_id,
    i.created_at
  from public.invoices i
  where i.org_id = p_org
    and i.created_at >= p_from_ts
    and i.created_at < p_to_ts
    and not public.is_test_customer(i.customer_id)
$function$;

-- report_pnl
create or replace function public.report_pnl(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- GST portion of what was paid, prorated by each invoice's own gst/total ratio
      'gst', (select coalesce(round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b),
      'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)
    ),
    'expenses_by_category', case when public.is_master() then coalesce((
      select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
      from (
        select category, sum(amount) as amount
        from public.expenses
        where org_id = v_org and date >= p_from and date <= p_to
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
$function$;

-- report_sales_service
create or replace function public.report_sales_service(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_sales_service: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with b as (
    select * from public._report_invoice_base(v_org, v_from, v_to)
  ),
  item_qty as (
    select ii.invoice_id, sum(ii.qty)::bigint as qty
    from public.invoice_items ii
    join b on b.invoice_id = ii.invoice_id
    where ii.org_id = v_org
    group by ii.invoice_id
  ),
  cls as (
    select b.class,
           count(*) as cnt,
           coalesce(sum(iq.qty), 0) as item_qty,
           sum(b.total) as total,
           sum(b.gst) as gst,
           sum(b.amount_paid) as collected
    from b
    left join item_qty iq on iq.invoice_id = b.invoice_id
    group by b.class
  ),
  by_class as (
    select k.key,
           jsonb_build_object(
             'count', coalesce(c.cnt, 0),
             -- units sold only means something for sales; the other classes have no unit concept
             'qty', case when k.key = 'sales' then coalesce(c.item_qty, 0) else coalesce(c.cnt, 0) end,
             'total', coalesce(c.total, 0),
             'gst', coalesce(c.gst, 0),
             'net', coalesce(c.total, 0) - coalesce(c.gst, 0),
             'collected', coalesce(c.collected, 0)
           ) as obj,
           coalesce(c.total, 0) as total
    from (values ('sales'), ('service'), ('amc'), ('rental')) k(key)
    left join cls c on c.class = k.key
  ),
  visits as (
    select sv.technician_id, count(*) as cnt, coalesce(sum(sv.service_charge), 0) as revenue
    from public.service_visits sv
    where sv.org_id = v_org and sv.timer_start >= v_from and sv.timer_start < v_to
      and not public._visit_is_test(sv.id)
    group by sv.technician_id
  )
  select jsonb_build_object(
    'by_class', (select jsonb_object_agg(key, obj) from by_class),
    'totals', jsonb_build_object(
      'count', (select count(*) from b),
      'total', (select coalesce(sum(total), 0) from b),
      'gst', (select coalesce(sum(gst), 0) from b),
      'net', (select coalesce(sum(total) - sum(gst), 0) from b),
      'collected', (select coalesce(sum(amount_paid), 0) from b)
    ),
    'by_invoice_type', coalesce((
      select jsonb_agg(jsonb_build_object('type', t.invoice_type, 'count', t.cnt, 'total', t.total) order by t.invoice_type)
      from (select invoice_type, count(*) as cnt, sum(total) as total from b group by invoice_type) t
    ), '[]'::jsonb),
    'service_visits', (select coalesce(sum(cnt), 0) from visits),
    'calls', (select count(*) from public.call_logs cl where cl.org_id = v_org and cl.called_at >= v_from and cl.called_at < v_to),
    'technicians', coalesce((
      select jsonb_agg(jsonb_build_object('technician_id', v.technician_id, 'name', coalesce(p.full_name, '—'), 'count', v.cnt, 'revenue', v.revenue)
                       order by v.revenue desc, coalesce(p.full_name, '—'), v.technician_id)
      from visits v
      left join public.technicians t on t.id = v.technician_id
      left join public.profiles p on p.id = t.profile_id
    ), '[]'::jsonb),
    -- average invoice value of a service call (service invoices, GST-inclusive like the tile)
    'avg_value_per_service_call', (
      select case when (obj->>'count')::numeric > 0 then round((obj->>'total')::numeric / (obj->>'count')::numeric, 2) else 0 end
      from by_class where key = 'service'
    )
  ) into v_result;
  return v_result;
end;
$function$;

-- report_customer_totals
create or replace function public.report_customer_totals(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_customer_totals: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with buyers as (
    select b.customer_id, sum(b.total) as revenue
    from public._report_invoice_base(v_org, v_from, v_to) b
    group by b.customer_id
  ),
  flagged as (
    select y.customer_id, y.revenue,
           exists (select 1 from public.invoices i
                   where i.org_id = v_org and i.customer_id = y.customer_id and i.created_at < v_from) as repeat
    from buyers y
  )
  select jsonb_build_object(
    'total_customers', (select count(*) from public.customers where org_id = v_org and not is_test),
    'new_customers', (select count(*) from public.customers where org_id = v_org and not is_test and created_at >= v_from and created_at < v_to),
    'buying_customers', (select count(*) from flagged),
    'new_buyers', (select count(*) from flagged where not repeat),
    'repeat_buyers', (select count(*) from flagged where repeat),
    'repeat_rate_percent', (select case when count(*) > 0 then round(count(*) filter (where repeat) * 100.0 / count(*), 1) end from flagged),
    'avg_revenue_per_buyer', (select case when count(*) > 0 then round(sum(revenue) / count(*), 2) else 0 end from flagged)
  ) into v_result;
  return v_result;
end;
$function$;

-- report_product_sales
create or replace function public.report_product_sales(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_product_sales: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with agg as (
    select ii.item_type,
           ii.item_id,
           sum(ii.qty)::bigint as qty,
           count(distinct ii.invoice_id) as invoice_count,
           sum(ii.qty * ii.price - ii.discount) as revenue,
           bool_or(ii.cost is null) as missing_cost,
           sum(ii.qty * ii.cost) as cost_sum
    from public.invoice_items ii
    where ii.org_id = v_org
      and not public._invoice_is_test(ii.invoice_id)
      and ii.item_type in ('product', 'spare')
      and ii.created_at >= v_from and ii.created_at < v_to
    group by ii.item_type, ii.item_id
  ),
  tot as (select coalesce(sum(revenue), 0) as revenue from agg),
  rows as (
    select a.item_type,
           a.item_id,
           coalesce(p.name, s.name, '—') as name,
           p.category as category,
           a.qty,
           a.invoice_count,
           round(a.revenue, 2) as revenue,
           case when a.missing_cost then null else round(a.cost_sum, 2) end as cost,
           case when a.missing_cost then null else round(a.revenue - a.cost_sum, 2) end as profit,
           case when not a.missing_cost and a.revenue > 0 then round((a.revenue - a.cost_sum) / a.revenue * 100, 1) end as margin_percent,
           case when t.revenue > 0 then round(a.revenue / t.revenue * 100, 1) else 0 end as share_percent,
           case when a.qty > 0 then round(a.revenue / a.qty, 2) else 0 end as avg_price
    from agg a
    cross join tot t
    left join public.products p on a.item_type = 'product' and p.id = a.item_id and p.org_id = v_org
    left join public.spares s on a.item_type = 'spare' and s.id = a.item_id and s.org_id = v_org
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'item_type', r.item_type,
      'item_id', r.item_id,
      'name', r.name,
      'category', r.category,
      'qty', r.qty,
      'invoice_count', r.invoice_count,
      'revenue', r.revenue,
      'cost', r.cost,
      'profit', r.profit,
      'margin_percent', r.margin_percent,
      'share_percent', r.share_percent,
      'avg_price', r.avg_price
    ) order by r.revenue desc, r.name, r.item_id), '[]'::jsonb)
  into v_result
  from rows r;
  return v_result;
end;
$function$;

-- report_coverage
create or replace function public.report_coverage(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_all_months integer;
  v_first date;     -- first kept month (1st of month)
  v_months integer;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_coverage: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  -- month count of the plain-date range, newest 36 kept
  v_all_months := greatest(0, (extract(year from p_to)::int - extract(year from p_from)::int) * 12
                              + extract(month from p_to)::int - extract(month from p_from)::int + 1);
  v_months := least(v_all_months, 36);
  v_first := (date_trunc('month', p_to::timestamp) - make_interval(months => greatest(v_months - 1, 0)))::date;

  with m as (
    select ms::date as ms, (ms + interval '1 month' - interval '1 day')::date as me
    from generate_series(v_first::timestamp, date_trunc('month', p_to::timestamp), interval '1 month') ms
    where v_months > 0
  ),
  months as (
    select m.ms, m.me, to_char(m.ms, 'YYYY-MM') as month,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'warranty' and not public.is_test_customer(t.customer_id)
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as w_visits,
      (select count(*) from public.warranties w where w.org_id = v_org and not public.is_test_customer(w.customer_id) and w.start_date <= m.me and w.expiry_date >= m.ms) as w_active,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'amc' and not public.is_test_customer(t.customer_id)
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as a_visits,
      (select count(*) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id) and c.start_date <= m.me and c.expiry_date >= m.ms) as a_active,
      (select coalesce(sum(coalesce(p.price_per_year, p.price / greatest(p.years, 1)) / 12), 0) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id) and c.start_date <= m.me and c.expiry_date >= m.ms) as a_value,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'rental' and not public.is_test_customer(t.customer_id)
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as r_visits,
      (select count(*) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and not public.is_test_customer(c.customer_id) and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_active,
      (select coalesce(sum(p.monthly_rate), 0) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and not public.is_test_customer(c.customer_id) and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_value
    from m
  ),
  inst as (
    select il.technician_id, sum(il.qty)::bigint as qty
    from public.installations_logged il
    where il.org_id = v_org and not public._visit_is_test(il.visit_id) and il.created_at >= v_from and il.created_at < v_to
    group by il.technician_id
  ),
  vis as (
    select sv.technician_id, count(*) as cnt
    from public.service_visits sv
    where sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  agg as (
    select
      (select coalesce(sum(qty), 0) from inst) as installs,
      (select coalesce(sum(ii.qty), 0) from public.invoice_items ii
        where ii.org_id = v_org and not public._invoice_is_test(ii.invoice_id) and ii.item_type = 'product' and ii.created_at >= v_from and ii.created_at < v_to) as units_sold,
      (select coalesce(sum(cnt), 0) from vis) as visits,
      (select count(*) from (select technician_id from inst union select technician_id from vis) x) as tech_count
  )
  select jsonb_build_object(
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', mo.month,
        'warranty', jsonb_build_object('visits', mo.w_visits, 'active', mo.w_active),
        'amc', jsonb_build_object('visits', mo.a_visits, 'active', mo.a_active, 'plan_value', round(mo.a_value, 2)),
        'rental', jsonb_build_object('visits', mo.r_visits, 'active', mo.r_active, 'plan_value', round(mo.r_value, 2))
      ) order by mo.ms) from months mo), '[]'::jsonb),
    'truncated', v_all_months > 36,
    'installation', jsonb_build_object(
      'installs', a.installs,
      'months_count', greatest(1, v_months),
      'technician_count', a.tech_count,
      'per_technician_per_month', case when a.tech_count > 0 then round(a.installs::numeric / a.tech_count / greatest(1, v_months), 2) end,
      'units_sold', a.units_sold,
      'per_product_sold', case when a.units_sold > 0 then round(a.installs::numeric / a.units_sold, 2) end,
      'visits', a.visits,
      'per_visit', case when a.visits > 0 then round(a.installs::numeric / a.visits, 2) end,
      'by_technician', coalesce((
        select jsonb_agg(jsonb_build_object('technician_id', i.technician_id, 'name', coalesce(p.full_name, '—'), 'installs', i.qty,
                                            'per_month', round(i.qty::numeric / greatest(1, v_months), 2))
                         order by i.qty desc, coalesce(p.full_name, '—'), i.technician_id)
        from inst i
        left join public.technicians t on t.id = i.technician_id
        left join public.profiles p on p.id = t.profile_id
      ), '[]'::jsonb)
    )
  ) into v_result
  from agg a;
  return v_result;
end;
$function$;

-- report_feedback
create or replace function public.report_feedback(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_feedback: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with rt as (
    select r.id, r.stars, r.review, r.created_at, r.visit_id
    from public.ratings r
    join public.service_visits sv on sv.id = r.visit_id and sv.org_id = v_org
    where r.org_id = v_org and not public._visit_is_test(r.visit_id) and r.created_at >= v_from and r.created_at < v_to
  ),
  reason as (
    select distinct on (n.ref_id) n.ref_id, n.body
    from public.notifications n
    where n.org_id = v_org and n.type = 'low_rating' and n.ref_id in (select id from rt where stars < 4.5)
    order by n.ref_id, n.created_at desc
  )
  select jsonb_build_object(
    'stars_distribution', (
      select jsonb_agg(jsonb_build_object('stars', s.stars, 'count', (select count(*) from rt where round(rt.stars) = s.stars)) order by s.stars)
      from generate_series(1, 5) s(stars)
    ),
    'average_rating', (select round(avg(stars), 2) from rt),
    'trend', coalesce((
      select jsonb_agg(jsonb_build_object('date', to_char(d.day, 'YYYY-MM-DD'), 'average_rating', d.avg_stars) order by d.day)
      from (select (created_at at time zone 'Asia/Kolkata')::date as day, round(avg(stars), 2) as avg_stars from rt group by 1) d
    ), '[]'::jsonb),
    'low_rating_entries', coalesce((
      select jsonb_agg(jsonb_build_object(
          'rating_id', l.id,
          'stars', l.stars,
          'review', l.review,
          'reason', case when rs.body is null then null else coalesce(substring(rs.body from 'Reason:\s*(.*)$'), rs.body) end,
          'created_at', l.created_at,
          'customer_name', c.name,
          'technician_name', p.full_name
        ) order by l.created_at, l.id)
      from rt l
      left join reason rs on rs.ref_id = l.id
      left join public.service_visits sv on sv.id = l.visit_id
      left join public.service_tickets t on t.id = sv.ticket_id
      left join public.customers c on c.id = t.customer_id
      left join public.technicians tc on tc.id = sv.technician_id
      left join public.profiles p on p.id = tc.profile_id
      where l.stars < 4.5
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;

-- report_ops_resolution
create or replace function public.report_ops_resolution(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_ops_resolution: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  select jsonb_build_object(
    'resolved_within_24h', count(*) filter (where t.updated_at - t.created_at <= interval '24 hours'),
    'total_completed', count(*),
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= interval '24 hours') * 100.0 / count(*), 1) end
  ) into v_result
  from public.service_tickets t
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$function$;

-- report_performance
create or replace function public.report_performance(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_performance: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with vis as (
    select sv.technician_id,
           count(*) as jobs,
           coalesce(sum(sv.service_charge), 0) as revenue,
           count(*) filter (where sv.needs_revisit is not true) as on_time,
           count(*) filter (where sv.timer_start is not null and sv.timer_end is not null) as timed,
           coalesce(sum(greatest(0, round(extract(epoch from (sv.timer_end - sv.timer_start)) / 60))) filter (where sv.timer_start is not null and sv.timer_end is not null), 0) as minutes
    from public.service_visits sv
    where sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  rat as (
    select sv.technician_id, sum(r.stars) as star_sum, count(*) as cnt
    from public.ratings r
    join public.service_visits sv on sv.id = r.visit_id
    where r.org_id = v_org and sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  led as (
    select l.owner_id as technician_id, count(*) as total, count(*) filter (where l.status = 'won') as won
    from public.leads l
    where l.org_id = v_org and not l.is_test and l.owner_id is not null and l.created_at >= v_from and l.created_at < v_to
    group by l.owner_id
  ),
  duty as (
    select a.technician_id, sum(extract(epoch from (a.check_out_at - a.check_in_at)) / 3600.0) as hours
    from public.attendance a
    where a.org_id = v_org and a.date >= p_from and a.date <= p_to
      and a.check_in_at is not null and a.check_out_at is not null and a.check_out_at > a.check_in_at
    group by a.technician_id
  ),
  inst as (
    select il.technician_id, sum(il.qty)::bigint as qty
    from public.installations_logged il
    where il.org_id = v_org and not public._visit_is_test(il.visit_id) and il.created_at >= v_from and il.created_at < v_to
    group by il.technician_id
  ),
  who as (
    select technician_id from vis union select technician_id from led
  ),
  rows as (
    select w.technician_id,
           coalesce(p.full_name, '—') as name,
           coalesce(v.jobs, 0) as jobs,
           case when coalesce(v.jobs, 0) > 0 then round(v.on_time * 100.0 / v.jobs, 1) end as on_time_percent,
           coalesce(v.revenue, 0) as revenue,
           case when coalesce(r.cnt, 0) > 0 then round(r.star_sum / r.cnt, 1) end as avg_rating,
           coalesce(r.cnt, 0) as review_count,
           case when coalesce(l.total, 0) > 0 then round(l.won * 100.0 / l.total, 1) end as conversion_percent,
           case when coalesce(v.timed, 0) > 0 then round(v.minutes::numeric / v.timed) end as avg_completion_minutes,
           case when coalesce(d.hours, 0) > 0 then round(coalesce(v.jobs, 0) / d.hours::numeric, 2) end as productivity,
           coalesce(i.qty, 0) as installations
    from who w
    left join vis v on v.technician_id = w.technician_id
    left join rat r on r.technician_id = w.technician_id
    left join led l on l.technician_id = w.technician_id
    left join duty d on d.technician_id = w.technician_id
    left join inst i on i.technician_id = w.technician_id
    left join public.technicians t on t.id = w.technician_id
    left join public.profiles p on p.id = t.profile_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.technician_id,
      'name', x.name,
      'role', 'technician',
      'jobs_done', x.jobs,
      'on_time_percent', x.on_time_percent,
      'revenue', x.revenue,
      'avg_rating', x.avg_rating,
      'review_count', x.review_count,
      'conversion_percent', x.conversion_percent,
      'avg_completion_minutes', x.avg_completion_minutes,
      'productivity_jobs_per_hour', x.productivity,
      'installations', x.installations
    ) order by x.revenue desc, x.name, x.technician_id), '[]'::jsonb)
  into v_result
  from rows x;
  return v_result;
end;
$function$;

-- _technician_paid_earning
create or replace function public._technician_paid_earning(p_org_id uuid, p_technician_id uuid, p_since timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(v.service_charge), 0)::numeric(12, 2)
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  join public.invoices i on i.id = st.invoice_id
  where v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and st.status = 'completed'
    and v.timer_end is not null
    and v.timer_end >= p_since
    and i.org_id = p_org_id
    and i.payment_status = 'paid'
    and not public.is_test_customer(st.customer_id);
$function$;

-- technician_attributed_revenue
create or replace function public.technician_attributed_revenue(p_org_id uuid, p_technician_id uuid, p_period date)
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
    and not public._visit_is_test(v.id)
    and v.timer_end >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and v.timer_end < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_attributed_sales
create or replace function public.technician_attributed_sales(p_org_id uuid, p_technician_id uuid, p_period date)
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
    and not public.is_test_customer(i.customer_id)
    and i.created_at >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and i.created_at < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_finder_conversions
create or replace function public.technician_finder_conversions(p_org_id uuid, p_technician_id uuid, p_period date)
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
    and not public.is_test_customer(st.customer_id)
    and v.timer_end is not null
    and v.timer_end >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and v.timer_end < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_installation_count
create or replace function public.technician_installation_count(p_org_id uuid, p_technician_id uuid, p_period date)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(il.qty), 0)::integer
  from public.installations_logged il
  where il.org_id = p_org_id
    and il.technician_id = p_technician_id
    and not public._visit_is_test(il.visit_id)
    and il.created_at >= (date_trunc('month', p_period)::date::timestamp at time zone 'Asia/Kolkata')
    and il.created_at < ((date_trunc('month', p_period)::date + interval '1 month')::timestamp at time zone 'Asia/Kolkata');
$function$;

-- technician_kpi_summary
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

-- reward_candidates
create or replace function public.reward_candidates(p_org_id uuid, p_period date)
 RETURNS TABLE(category reward_category, technician_id uuid, metric numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', p_period)::date;
  v_late_cutoff time;
begin
  if not public.is_staff() then
    raise exception 'reward_candidates: staff role required';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'reward_candidates: org mismatch';
  end if;

  select late_cutoff into v_late_cutoff from public.settings where org_id = p_org_id;
  v_late_cutoff := coalesce(v_late_cutoff, '09:15:00'::time);

  return query
  with org_days as (
    -- "Expected working days" is derived from the data itself (no
    -- weekly-off/working-days master exists in this schema — see file
    -- header): every calendar date this month at least one technician in
    -- the org has an attendance row for, i.e. a day the org operated.
    select distinct a.date
    from public.attendance a
    where a.org_id = p_org_id
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
  ),
  org_day_count as (
    select count(*) as n from org_days
  ),
  late_hours_agg as (
    -- Same "hours late" derivation as technician_late_hours() (hr_functions.sql),
    -- inlined here since this runs as one set-based query across all technicians.
    select a.technician_id,
      coalesce(sum(
        greatest(0, extract(epoch from ((a.check_in_at at time zone 'Asia/Kolkata')::time - v_late_cutoff)) / 3600.0)
      ), 0) as late_hours
    from public.attendance a
    where a.org_id = p_org_id
      and a.is_late = true
      and a.check_in_at is not null
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
    group by a.technician_id
  ),
  attendance_agg as (
    -- Full attendance: a row on every org-operating day this month.
    select a.technician_id, count(distinct a.date) as days_present
    from public.attendance a
    where a.org_id = p_org_id
      and a.date >= v_period
      and a.date < (v_period + interval '1 month')::date
    group by a.technician_id
    having count(distinct a.date) = (select n from org_day_count)
  ),
  attendance_eligible as (
    select aa.technician_id, coalesce(lh.late_hours, 0) as late_hours
    from attendance_agg aa
    left join late_hours_agg lh on lh.technician_id = aa.technician_id
    where coalesce(lh.late_hours, 0) <= 3
  ),
  review_agg as (
    select v.technician_id, count(*) as review_count
    from public.ratings r
    join public.service_visits v on v.id = r.visit_id
    where v.org_id = p_org_id
      and not public._visit_is_test(v.id)
      and r.created_at >= v_period
      and r.created_at < v_period + interval '1 month'
    group by v.technician_id
  ),
  revenue_agg as (
    select t.id as technician_id,
      public.technician_attributed_revenue(p_org_id, t.id, v_period)
        + public.technician_attributed_sales(p_org_id, t.id, v_period) as revenue
    from public.technicians t
    where t.org_id = p_org_id and t.is_active
  ),
  referral_agg as (
    select t.id as technician_id,
      public.technician_finder_conversions(p_org_id, t.id, v_period) as referrals
    from public.technicians t
    where t.org_id = p_org_id and t.is_active
  )
  select 'attendance'::reward_category, ae.technician_id, ae.late_hours::numeric
  from attendance_eligible ae
  where (select n from org_day_count) > 0
    and ae.late_hours = (select min(late_hours) from attendance_eligible)
  union all
  select 'highest_review'::reward_category, ra.technician_id, ra.review_count::numeric
  from review_agg ra
  where ra.review_count >= 51
    and ra.review_count = (select max(review_count) from review_agg where review_count >= 51)
  union all
  select 'highest_revenue'::reward_category, rv.technician_id, rv.revenue::numeric
  from revenue_agg rv
  where rv.revenue >= 150000
    and rv.revenue = (select max(revenue) from revenue_agg where revenue >= 150000)
  union all
  select 'highest_referral'::reward_category, rf.technician_id, rf.referrals::numeric
  from referral_agg rf
  where rf.referrals >= 20
    and rf.referrals = (select max(referrals) from referral_agg where referrals >= 20);
end;
$function$;

-- compute_incentives
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

  return query
    select * from public.incentives_earned
    where org_id = p_org_id and period = v_period
    order by technician_id;
end;
$function$;

-- get_technician_public_stats
create or replace function public.get_technician_public_stats(p_technician_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid;
  v_avg_rating numeric;
  v_completed_count integer;
begin
  select org_id into v_org_id from public.technicians where id = p_technician_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    raise exception 'get_technician_public_stats: technician % not found', p_technician_id;
  end if;

  select round(avg(r.stars), 1) into v_avg_rating
  from public.ratings r
  join public.service_visits sv on sv.id = r.visit_id
  where sv.technician_id = p_technician_id
    and not public._visit_is_test(sv.id);

  select count(*) into v_completed_count
  from public.service_visits sv
  where sv.technician_id = p_technician_id and sv.timer_end is not null
    and not public._visit_is_test(sv.id);

  return jsonb_build_object('avg_rating', v_avg_rating, 'completed_count', v_completed_count);
end;
$function$;

-- get_lead_funnel
create or replace function public.get_lead_funnel(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_result jsonb;
begin
  if not public.is_staff() then
    raise exception 'not permitted: only staff can view the lead funnel';
  end if;

  with lr as (
    select l.id, l.status, l.source,
      (select max(case s when 'new' then 1 when 'contacted' then 2 when 'quoted' then 3 when 'won' then 4 end)
         from public.lead_stage_log g, lateral (values (g.to_status), (g.from_status)) v(s)
         where g.lead_id = l.id) as rank
    from public.leads l
    where l.org_id = v_org and not l.is_test and l.created_at >= p_from and l.created_at <= p_to
  )
  select jsonb_build_object(
    'total', (select count(*) from lr),
    'by_status', jsonb_build_object(
      'new', (select count(*) from lr where status = 'new'),
      'contacted', (select count(*) from lr where status = 'contacted'),
      'quoted', (select count(*) from lr where status = 'quoted'),
      'won', (select count(*) from lr where status = 'won'),
      'lost', (select count(*) from lr where status = 'lost')),
    'reached', jsonb_build_object(
      'created', (select count(*) from lr where rank >= 1),
      'contacted', (select count(*) from lr where rank >= 2),
      'quoted', (select count(*) from lr where rank >= 3),
      'won', (select count(*) from lr where rank >= 4)),
    'lost_stage_known', (select count(*) from lr where status = 'lost' and rank is not null),
    'lost_stage_unknown', (select count(*) from lr where status = 'lost' and rank is null),
    'by_source', coalesce((
      select jsonb_agg(jsonb_build_object('source', source, 'total', total, 'won', won) order by total desc, source)
      from (select source, count(*) as total, count(*) filter (where status = 'won') as won from lr group by source) s
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;

-- followup_counts
create or replace function public.followup_counts(p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_scope text;
  v_overdue int;
  v_today_n int;
  v_people jsonb := '[]'::jsonb;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  -- Dead-man's switch: only a master's poll may raise the alert (see _lead_cron_deadman_check).
  -- sales_admin callers do nothing here and get the identical response.
  if public.current_role() = 'master' then
    begin
      perform public._lead_cron_deadman_check();
    exception when others then
      null; -- a broken monitor must never break the menu badge
    end;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  -- lead follow-ups (as before) plus open post-service follow-ups (ticket rows; assigned_to NULL = all sales staff)
  select
    count(*) filter (where public._lead_ist_date(x.due_at) < v_today),
    count(*) filter (where public._lead_ist_date(x.due_at) = v_today)
  into v_overdue, v_today_n
  from (
    select f.due_at, ap.id as ap_id
    from public.lead_followups f
    join public.leads l on l.id = f.lead_id
    left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
    where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
    union all
    select f.due_at, ap.id
    from public.lead_followups f
    left join public.profiles ap on ap.id = f.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
    where f.org_id = v_org and f.status = 'open' and f.ticket_id is not null and not public.is_test_customer(f.customer_id)
  ) x
  where (
    v_scope = 'all'
    or (v_scope = 'mine' and x.ap_id = v_uid)
    or (v_scope = 'unassigned' and x.ap_id is null)
    or (v_scope = 'mine_unassigned' and (x.ap_id = v_uid or x.ap_id is null))
    or (v_scope = 'person' and x.ap_id = p_assignee)
  );

  -- master: who holds how much (assignees only; unassigned is the remainder)
  if public.current_role() = 'master' then
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.full_name, 'overdue', x.o, 'today', x.t) order by x.full_name), '[]'::jsonb)
    into v_people
    from (
      select y.id, y.full_name,
        count(*) filter (where public._lead_ist_date(y.due_at) < v_today) as o,
        count(*) filter (where public._lead_ist_date(y.due_at) = v_today) as t
      from (
        select ap.id, ap.full_name, f.due_at
        from public.lead_followups f
        join public.leads l on l.id = f.lead_id
        join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
        where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
        union all
        select ap.id, ap.full_name, f.due_at
        from public.lead_followups f
        join public.profiles ap on ap.id = f.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
        where f.org_id = v_org and f.status = 'open' and f.ticket_id is not null and not public.is_test_customer(f.customer_id)
      ) y
      group by y.id, y.full_name
    ) x;
  end if;

  return jsonb_build_object('overdue', v_overdue, 'today', v_today_n, 'total', v_overdue + v_today_n, 'by_person', v_people);
end;
$function$;

-- list_followups
create or replace function public.list_followups(p_bucket text DEFAULT 'all'::text, p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_stuck_only boolean DEFAULT false, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(followup_id uuid, lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, due_at timestamp with time zone, followup_type lead_followup_type, followup_note text, is_exact_time boolean, postpone_count integer, is_stuck boolean, bucket text, last_outcome_code text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone, assignee_id uuid, assignee_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_stuck integer;
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  if p_bucket not in ('all', 'overdue', 'today', 'upcoming') then
    raise exception 'invalid bucket %', p_bucket;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;
  select coalesce(s.lead_stuck_postpones, 3) into v_stuck from public.settings s where s.org_id = v_org;
  v_stuck := coalesce(v_stuck, 3);

  return query
  select
    f.id, l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, coalesce(l.kind_key, l.kind::text), l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    f.due_at, f.type, f.note, f.is_exact_time, l.postpone_count, (l.postpone_count >= v_stuck),
    case
      when public._lead_ist_date(f.due_at) < v_today then 'overdue'
      when public._lead_ist_date(f.due_at) = v_today then 'today'
      when public._lead_ist_date(f.due_at) <= v_today + 7 then 'upcoming'
      else 'later'
    end,
    lo.code, lo.label_en, lo.label_ta, lo.note, lo.at,
    ap.id, ap.full_name
  from public.lead_followups f
  join public.leads l on l.id = f.lead_id
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.code, o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where f.org_id = v_org and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or coalesce(l.kind_key, l.kind::text) = p_kind)
    and (not p_stuck_only or l.postpone_count >= v_stuck)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
    and (
      p_bucket = 'all'
      or (p_bucket = 'overdue' and public._lead_ist_date(f.due_at) < v_today)
      or (p_bucket = 'today' and public._lead_ist_date(f.due_at) = v_today)
      or (p_bucket = 'upcoming' and public._lead_ist_date(f.due_at) > v_today and public._lead_ist_date(f.due_at) <= v_today + 7)
    )
  order by f.due_at asc;
end;
$function$;

-- list_leads_without_followup
create or replace function public.list_leads_without_followup(p_stage lead_status DEFAULT NULL::lead_status, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(lead_id uuid, lead_name text, mobile text, source text, kind text, enquiry_type enquiry_type, lead_status lead_status, product_name text, created_at timestamp with time zone, postpone_count integer, assignee_id uuid, assignee_name text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view leads without a follow-up';
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  return query
  select
    l.id, coalesce(c.name, l.name), coalesce(l.mobile, c.mobile), l.source, coalesce(l.kind_key, l.kind::text), l.enquiry_type, l.status,
    coalesce(
      (select coalesce(sp.name, pr.name) from public.lead_items li
         left join public.spares sp on sp.id = li.spare_id
         left join public.products pr on pr.id = li.product_id
         where li.lead_id = l.id order by li.created_at limit 1),
      (select pr2.name from public.products pr2 where pr2.id = l.product_id)
    ),
    l.created_at, l.postpone_count, ap.id, ap.full_name,
    lo.label_en, lo.label_ta, lo.note, lo.at
  from public.leads l
  left join public.customers c on c.id = l.customer_id
  left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select o.label_en, o.label_ta, a.note, a.at
    from public.lead_activities a join public.lead_outcomes o on o.id = a.outcome_id
    where a.lead_id = l.id order by a.at desc limit 1
  ) lo on true
  where l.org_id = v_org and l.status not in ('won', 'lost') and not l.is_test
    and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
    and (p_stage is null or l.status = p_stage)
    and (p_source is null or l.source = p_source)
    and (p_kind is null or coalesce(l.kind_key, l.kind::text) = p_kind)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
  order by l.created_at asc, l.id asc;
end;
$function$;

-- list_post_service_followups
create or replace function public.list_post_service_followups(p_bucket text DEFAULT 'all'::text, p_scope text DEFAULT 'auto'::text, p_assignee uuid DEFAULT NULL::uuid)
 RETURNS TABLE(followup_id uuid, ticket_id uuid, customer_id uuid, customer_name text, mobile text, complaint text, ticket_type text, product_name text, created_at timestamp with time zone, due_at timestamp with time zone, note text, bucket text, assignee_id uuid, assignee_name text, attempts integer, last_outcome_code text, last_outcome_label_en text, last_outcome_label_ta text, last_outcome_note text, last_outcome_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public.current_org_id();
  v_uid uuid := auth.uid();
  v_today date := public._lead_ist_date(now());
  v_scope text;
begin
  if not public.is_sales_staff() then
    raise exception 'not permitted: only master or sales_admin can view follow-ups';
  end if;
  if p_bucket not in ('all', 'overdue', 'today', 'upcoming') then
    raise exception 'invalid bucket %', p_bucket;
  end if;
  v_scope := public._lead_resolve_scope(p_scope);
  if v_scope = 'person' and p_assignee is null then
    raise exception 'person scope needs an assignee';
  end if;

  return query
  select
    f.id, t.id, c.id, c.name, c.mobile, t.name_of_complaint, t.type::text,
    coalesce(pr.name, t.unlisted_product_name),
    f.created_at, f.due_at, f.note,
    case
      when public._lead_ist_date(f.due_at) < v_today then 'overdue'
      when public._lead_ist_date(f.due_at) = v_today then 'today'
      when public._lead_ist_date(f.due_at) <= v_today + 7 then 'upcoming'
      else 'later'
    end,
    ap.id, ap.full_name,
    (select count(*)::int from public.post_service_calls k where k.followup_id = f.id),
    lc.outcome_code, lc.label_en, lc.label_ta, lc.note, lc.called_at
  from public.lead_followups f
  join public.service_tickets t on t.id = f.ticket_id
  join public.customers c on c.id = f.customer_id
  left join public.products pr on pr.id = t.product_id
  left join public.profiles ap on ap.id = f.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
  left join lateral (
    select k.outcome_code, o.label_en, o.label_ta, k.note, k.called_at
    from public.post_service_calls k join public.post_service_outcomes o on o.id = k.outcome_id
    where k.followup_id = f.id order by k.called_at desc limit 1
  ) lc on true
  where f.org_id = v_org and f.status = 'open' and f.ticket_id is not null and not public.is_test_customer(f.customer_id)
    and (
      v_scope = 'all'
      or (v_scope = 'mine' and ap.id = v_uid)
      or (v_scope = 'unassigned' and ap.id is null)
      or (v_scope = 'mine_unassigned' and (ap.id = v_uid or ap.id is null))
      or (v_scope = 'person' and ap.id = p_assignee)
    )
    and (
      p_bucket = 'all'
      or (p_bucket = 'overdue' and public._lead_ist_date(f.due_at) < v_today)
      or (p_bucket = 'today' and public._lead_ist_date(f.due_at) = v_today)
      or (p_bucket = 'upcoming' and public._lead_ist_date(f.due_at) > v_today and public._lead_ist_date(f.due_at) <= v_today + 7)
    )
  order by f.due_at asc;
end;
$function$;

-- _trg_lead_auto_assign
create or replace function public._trg_lead_auto_assign()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pick uuid;
begin
  -- never trust a client-supplied flag
  new.auto_assign_pending := false;

  if new.assigned_to is not null then
    return new;
  end if;
  if new.status in ('won', 'lost') then
    return new;
  end if;
  -- a test lead is never auto-assigned and never advances the rotation (it stays unassigned)
  if new.is_test then
    return new;
  end if;
  if not coalesce((select s.auto_assign_leads from public.settings s where s.org_id = new.org_id), false) then
    return new;
  end if;

  -- serialise per organisation so two simultaneous leads cannot pick the same person
  perform pg_advisory_xact_lock(hashtextextended('lead_rr:' || new.org_id::text, 0));

  v_pick := public._lead_rr_pick(new.org_id);
  if v_pick is null then
    new.auto_assign_pending := true;
    return new;
  end if;

  insert into public.lead_rotation (profile_id, org_id, last_auto_assigned_at)
  values (v_pick, new.org_id, clock_timestamp())
  on conflict (profile_id) do update set last_auto_assigned_at = excluded.last_auto_assigned_at;

  new.assigned_to := v_pick;
  return new;
end;
$function$;

-- run_lead_followup_notifications
create or replace function public.run_lead_followup_notifications(p_now timestamp with time zone DEFAULT now(), p_org_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org record;
  v_s record;
  v_r record;
  v_today date := public._lead_ist_date(p_now);
  v_time time := (p_now at time zone 'Asia/Kolkata')::time;
  v_start time;
  v_end time;
  v_reminder integer;
  v_n_today integer;
  v_n_overdue integer;
  v_n_stale integer;
  v_n_none integer;
  v_n_ps integer;
  v_names text;
  v_people text;
  v_unassigned integer;
  v_body text;
  v_f record;
  v_digests integer := 0;
  v_reminders integer := 0;
  v_stale_sent integer := 0;
  v_sent_any boolean;
  v_key text;
begin
  for v_org in select id from public.organizations where p_org_id is null or id = p_org_id loop
    select * into v_s from public.settings where org_id = v_org.id;
    v_start := coalesce(v_s.lead_work_start, '09:30');
    v_end := coalesce(v_s.lead_work_end, '19:00');
    v_reminder := coalesce(v_s.lead_reminder_minutes, 15);

    -- Digest + stale list: once per working day, from opening time until closing.
    if public._lead_is_working_day(v_org.id, v_today) and v_time >= v_start and v_time <= v_end then
      v_key := v_org.id::text || ':' || v_today::text;

      -- 1. digest
      if not exists (select 1 from public.lead_notification_log where kind = 'digest' and key = v_key) then
        insert into public.lead_notification_log (kind, key) values ('digest', v_key);
        v_sent_any := false;
        for v_r in
          select p.id, p.role from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        loop
          select
            count(*) filter (where public._lead_ist_date(f.due_at) = v_today),
            count(*) filter (where public._lead_ist_date(f.due_at) < v_today)
          into v_n_today, v_n_overdue
          from public.lead_followups f
          join public.leads l on l.id = f.lead_id
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
            and (v_r.role = 'master' or ap.id is null or ap.id = v_r.id);

          -- open leads nobody has scheduled (same visibility rule as the counts above)
          select count(*) into v_n_none
          from public.leads l
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where l.org_id = v_org.id and l.status not in ('won', 'lost') and not l.is_test
            and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
            and (v_r.role = 'master' or ap.id is null or ap.id = v_r.id);

          -- open post-service calls due today or overdue (same visibility rule; assigned_to NULL = all sales staff)
          select count(*) into v_n_ps
          from public.lead_followups f
          left join public.profiles ap on ap.id = f.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where f.org_id = v_org.id and f.status = 'open' and f.ticket_id is not null and not public.is_test_customer(f.customer_id)
            and public._lead_ist_date(f.due_at) <= v_today
            and (v_r.role = 'master' or ap.id is null or ap.id = v_r.id);

          if v_n_today + v_n_overdue + v_n_none + v_n_ps > 0 then
            v_body := format('%s due today, %s overdue. Open Daily Follow Up.', v_n_today, v_n_overdue);
            if v_r.role = 'master' then
              select count(*) filter (where ap.id is null) into v_unassigned
              from public.lead_followups f
              join public.leads l on l.id = f.lead_id
              left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
              where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
                and public._lead_ist_date(f.due_at) <= v_today;
              select string_agg(format('%s %s', x.full_name, x.n), ', ' order by x.full_name) into v_people
              from (
                select ap.full_name, count(*) as n
                from public.lead_followups f
                join public.leads l on l.id = f.lead_id
                join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
                where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
                  and public._lead_ist_date(f.due_at) <= v_today
                group by ap.id, ap.full_name
              ) x;
              if v_people is not null then
                v_body := v_body || format(' Unassigned: %s. By person: %s.', v_unassigned, v_people);
              end if;
            end if;
            if v_n_none > 0 then
              v_body := v_body || format(' %s lead(s) have no follow-up.', v_n_none);
            end if;
            if v_n_ps > 0 then
              v_body := v_body || format(' %s post-service call(s) due.', v_n_ps);
            end if;
            insert into public.notifications (org_id, user_id, type, title, body)
            values (v_org.id, v_r.id, 'lead_followup_digest', 'Follow-ups for today', v_body);
            v_sent_any := true;
          end if;
        end loop;
        if v_sent_any then
          v_digests := v_digests + 1;
        end if;
      end if;

      -- 3. overdue more than 24 hours
      if not exists (select 1 from public.lead_notification_log where kind = 'overdue24' and key = v_key) then
        insert into public.lead_notification_log (kind, key) values ('overdue24', v_key);
        v_sent_any := false;
        for v_r in
          select p.id, p.role from public.profiles p
          where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        loop
          -- the recipient's own list: sales_admin = own + unassigned, master = own + unassigned
          select count(*), string_agg(name, ', ' order by due_at)
          into v_n_stale, v_names
          from (
            select coalesce(c.name, l.name) as name, f.due_at
            from public.lead_followups f
            join public.leads l on l.id = f.lead_id
            left join public.customers c on c.id = l.customer_id
            left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
            where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
              and f.due_at < p_now - interval '24 hours'
              and (ap.id is null or ap.id = v_r.id)
            order by f.due_at limit 5
          ) s;
          select count(*) into v_n_stale
          from public.lead_followups f
          join public.leads l on l.id = f.lead_id
          left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
          where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
            and f.due_at < p_now - interval '24 hours'
            and (ap.id is null or ap.id = v_r.id);

          v_people := null;
          if v_r.role = 'master' then
            -- colleagues' overdue counts (master sees counts, not their lists)
            select string_agg(format('%s %s', x.full_name, x.n), ', ' order by x.full_name) into v_people
            from (
              select ap.full_name, count(*) as n
              from public.lead_followups f
              join public.leads l on l.id = f.lead_id
              join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin') and ap.id <> v_r.id
              where f.org_id = v_org.id and f.status = 'open' and l.status not in ('won', 'lost') and not l.is_test
                and f.due_at < p_now - interval '24 hours'
              group by ap.id, ap.full_name
            ) x;
          end if;

          if v_n_stale > 0 or v_people is not null then
            v_body := case when v_n_stale > 0 then format('%s lead(s): %s%s', v_n_stale, v_names, case when v_n_stale > 5 then ' …' else '' end) else null end;
            if v_people is not null then
              v_body := coalesce(v_body || ' · ', '') || 'By person: ' || v_people;
            end if;
            insert into public.notifications (org_id, user_id, type, title, body)
            values (v_org.id, v_r.id, 'lead_followup_overdue', 'Follow-ups overdue by more than 24 hours', v_body);
            v_sent_any := true;
          end if;
        end loop;
        if v_sent_any then
          v_stale_sent := v_stale_sent + 1;
        end if;
      end if;
    end if;

    -- 2. exact-time callback reminders (any day: staff may agree a Sunday call)
    for v_f in
      select f.id, f.due_at, l.id as lead_id, coalesce(c.name, l.name) as name, coalesce(l.mobile, c.mobile) as mobile, ap.id as assignee_id
      from public.lead_followups f
      join public.leads l on l.id = f.lead_id
      left join public.customers c on c.id = l.customer_id
      left join public.profiles ap on ap.id = l.assigned_to and ap.is_active and ap.role in ('master', 'sales_admin')
      where f.org_id = v_org.id and f.status = 'open' and f.is_exact_time and l.status not in ('won', 'lost') and not l.is_test
        and f.due_at >= p_now and f.due_at <= p_now + make_interval(mins => v_reminder)
        and not exists (select 1 from public.lead_notification_log g where g.kind = 'reminder' and g.key = f.id::text)
    loop
      insert into public.lead_notification_log (kind, key) values ('reminder', v_f.id::text);
      insert into public.notifications (org_id, user_id, type, title, body, ref_id)
      select v_org.id, p.id, 'lead_callback_reminder',
             format('Callback in %s min: %s', greatest(1, ceil(extract(epoch from (v_f.due_at - p_now)) / 60)::int), v_f.name),
             format('%s%s at %s IST', v_f.name, coalesce(' (' || v_f.mobile || ')', ''), to_char(v_f.due_at at time zone 'Asia/Kolkata', 'HH12:MI AM')),
             v_f.lead_id
      from public.profiles p
      where p.org_id = v_org.id and p.role in ('master', 'sales_admin') and p.is_active
        and (v_f.assignee_id is null or p.id = v_f.assignee_id);
      v_reminders := v_reminders + 1;
    end loop;
  end loop;

  return jsonb_build_object('digests', v_digests, 'reminders', v_reminders, 'overdue_lists', v_stale_sent, 'ran_at', p_now);
end;
$function$;

notify pgrst, 'reload schema';
