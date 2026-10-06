-- Reports correctness, migration 1 of 3: move the heavy report aggregations out of the browser.
--
-- Why: every report screen summed rows fetched through PostgREST, which silently truncates at
-- config.toml max_rows = 1000. Past 1000 invoices / items the totals were simply wrong, with no
-- error. These functions aggregate in SQL and return one small jsonb document.
--
-- ADDITIVE ONLY: nothing is dropped or replaced, so the deployed frontend keeps working until it
-- is switched over to these functions.
--
-- Conventions (all report_* functions):
--   * plain dates in (p_from date, p_to date); the window is half-open in IST:
--       [p_from 00:00 IST, (p_to + 1 day) 00:00 IST)
--   * SECURITY DEFINER, STABLE, search_path = public; the organisation comes from
--     current_org_id() (no org parameter); is_staff() is required;
--   * EXECUTE for authenticated only (anon and PUBLIC revoked - this project auto-grants anon).
--
-- Revenue classes (decision 1-2): one invoice, one class, counted once.
--   product invoice                                   -> sales
--   spare invoice linked from a service ticket that   -> service  (full invoice total, GST-inclusive)
--     has at least one service visit
--   spare invoice with no such ticket (counter sale)  -> sales
--   amc invoice -> amc,  rent invoice -> rental
-- Sales & Service and P&L both read the same helper set, so they agree by construction.

-- ── indexes (additive) ───────────────────────────────────────────────────
create index if not exists invoices_org_created_idx on public.invoices (org_id, created_at);
create index if not exists service_visits_org_timer_start_idx on public.service_visits (org_id, timer_start);
create index if not exists invoice_items_org_created_idx on public.invoice_items (org_id, created_at);
create index if not exists ratings_org_created_idx on public.ratings (org_id, created_at);
create index if not exists attendance_org_date_idx on public.attendance (org_id, date);

-- ── internal helpers (executable by nobody but the owner / the definer functions below) ──

-- Caller's organisation, after the staff check. Raises for anyone who is not staff.
create or replace function public._report_org()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_staff(), false) then
    raise exception 'not permitted: only staff can view reports';
  end if;
  return v_org;
end;
$$;
revoke all on function public._report_org() from public, anon, authenticated, service_role;

-- IST calendar date -> instant of its 00:00 IST (IST has no DST).
create or replace function public._report_ist_start(p_date date)
returns timestamptz
language sql
immutable
set search_path = public
as $$
  select (p_date::timestamp) at time zone 'Asia/Kolkata'
$$;
revoke all on function public._report_ist_start(date) from public, anon, authenticated, service_role;

-- Every in-window invoice exactly once, with its revenue class.
create or replace function public._report_invoice_base(p_org uuid, p_from_ts timestamptz, p_to_ts timestamptz)
returns table (
  invoice_id uuid,
  class text,
  invoice_type public.invoice_type,
  total numeric,
  gst numeric,
  amount_paid numeric,
  customer_id uuid,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
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
$$;
revoke all on function public._report_invoice_base(uuid, timestamptz, timestamptz) from public, anon, authenticated, service_role;

-- ── report_sales_service ─────────────────────────────────────────────────
create or replace function public.report_sales_service(p_from date, p_to date)
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
$$;
revoke all on function public.report_sales_service(date, date) from public, anon;
grant execute on function public.report_sales_service(date, date) to authenticated;

-- ── report_pnl ───────────────────────────────────────────────────────────
-- expenses_by_category is master-only (same as the expenses RLS policy): anyone else gets [].
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
  ),
  gl as (
    select cost
    from public.gift_logs
    where org_id = v_org and created_at >= v_from and created_at < v_to
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
$$;
revoke all on function public.report_pnl(date, date) from public, anon;
grant execute on function public.report_pnl(date, date) to authenticated;

-- ── report_top_customers ─────────────────────────────────────────────────
-- Ranked by invoiced total; ties broken by customer id so the order is stable. p_limit is
-- clamped to 1..200.
create or replace function public.report_top_customers(p_from date, p_to date, p_limit integer default 50)
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
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_top_customers: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with agg as (
    select b.customer_id,
           sum(b.total) as invoiced_total,
           sum(b.amount_paid) as collected_total,
           count(*) as invoice_count,
           min(b.created_at) as first_purchase_at,
           max(b.created_at) as last_purchase_at
    from public._report_invoice_base(v_org, v_from, v_to) b
    group by b.customer_id
  ),
  ranked as (
    select a.*, row_number() over (order by a.invoiced_total desc, a.customer_id) as rank
    from agg a
  ),
  top as (
    select * from ranked where rank <= v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'rank', t.rank,
      'customer_id', t.customer_id,
      'name', coalesce(c.name, '—'),
      'mobile', coalesce(c.mobile, '—'),
      'profession', c.profession,
      'area', ad.area,
      'pincode', ad.pincode,
      'invoiced_total', t.invoiced_total,
      'collected_total', t.collected_total,
      'invoice_count', t.invoice_count,
      'first_purchase_at', t.first_purchase_at,
      'last_purchase_at', t.last_purchase_at
    ) order by t.rank), '[]'::jsonb)
  into v_result
  from top t
  left join public.customers c on c.id = t.customer_id and c.org_id = v_org
  left join lateral (
    select a.area, a.pincode
    from public.addresses a
    where a.customer_id = t.customer_id and a.org_id = v_org
    order by a.is_primary desc, a.created_at, a.id
    limit 1
  ) ad on true;
  return v_result;
end;
$$;
revoke all on function public.report_top_customers(date, date, integer) from public, anon;
grant execute on function public.report_top_customers(date, date, integer) to authenticated;

-- ── report_customer_totals ───────────────────────────────────────────────
create or replace function public.report_customer_totals(p_from date, p_to date)
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
    'total_customers', (select count(*) from public.customers where org_id = v_org),
    'new_customers', (select count(*) from public.customers where org_id = v_org and created_at >= v_from and created_at < v_to),
    'buying_customers', (select count(*) from flagged),
    'new_buyers', (select count(*) from flagged where not repeat),
    'repeat_buyers', (select count(*) from flagged where repeat),
    'repeat_rate_percent', (select case when count(*) > 0 then round(count(*) filter (where repeat) * 100.0 / count(*), 1) end from flagged),
    'avg_revenue_per_buyer', (select case when count(*) > 0 then round(sum(revenue) / count(*), 2) else 0 end from flagged)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.report_customer_totals(date, date) from public, anon;
grant execute on function public.report_customer_totals(date, date) to authenticated;

-- ── report_product_sales ─────────────────────────────────────────────────
-- cost / profit / margin_percent are NULL as soon as one sold line has no cost snapshot
-- (never treated as zero cost). Gift lines are excluded (item_type product/spare only).
create or replace function public.report_product_sales(p_from date, p_to date)
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
$$;
revoke all on function public.report_product_sales(date, date) from public, anon;
grant execute on function public.report_product_sales(date, date) to authenticated;

notify pgrst, 'reload schema';
