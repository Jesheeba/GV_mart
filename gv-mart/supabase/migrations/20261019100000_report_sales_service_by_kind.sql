-- Sales & Invoices KPI tiles (batch-17 item 7): additive by_kind key in report_sales_service.
-- Design: docs/sales-invoices-kpi-design.md (branch docs/sales-invoices-kpi-design).
--   by_kind = { product, spare_counter, service, amc, rental }, each { count, total, gst, collected }, same invoice set
--   (_report_invoice_base: IST window, flagged test customers excluded) as by_class and totals.
--   product = type product; amc = type amc; rental = type rent; service = spare-type invoice linked to a ticket with a visit
--   (technician service invoice); spare_counter = every other spare-type invoice. Service invoices are NOT counted as spares.
-- Same signature, same ACL, every existing key unchanged (an old frontend ignores the new key).
-- Body below is the LIVE definition of 2026-10-13 with only the by_kind CTE and one result key added.
CREATE OR REPLACE FUNCTION public.report_sales_service(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
  -- Item 7 (Sales & Invoices tiles): the same invoice set split by what was sold.
  -- spare_counter = a spare-type invoice that is NOT a technician service invoice (class 'sales'); service invoices are their own kind.
  kind_rows as (
    select case
             when b.class = 'service' then 'service'
             when b.invoice_type = 'product' then 'product'
             when b.invoice_type = 'amc' then 'amc'
             when b.invoice_type = 'rent' then 'rental'
             when b.invoice_type = 'spare' then 'spare_counter'
           end as kind,
           count(*) as cnt, sum(b.total) as total, sum(b.gst) as gst, sum(b.amount_paid) as collected
    from b
    group by 1
  ),
  by_kind as (
    select k.key,
           jsonb_build_object(
             'count', coalesce(r.cnt, 0),
             'total', coalesce(r.total, 0),
             'gst', coalesce(r.gst, 0),
             'collected', coalesce(r.collected, 0)
           ) as obj
    from (values ('product'), ('spare_counter'), ('service'), ('amc'), ('rental')) k(key)
    left join kind_rows r on r.kind = k.key
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
    'by_kind', (select jsonb_object_agg(key, obj) from by_kind),
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
$$
;
revoke all on function public.report_sales_service(date, date) from public, anon;
grant execute on function public.report_sales_service(date, date) to authenticated;

notify pgrst, 'reload schema';
