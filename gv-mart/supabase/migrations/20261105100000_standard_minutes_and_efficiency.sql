-- P5: a standard-minutes master per service (complaint) type; an actual-vs-standard efficiency figure on the
-- technician performance report; the overrun buffer and the ops-resolution SLA move from hard-coded constants to
-- settings. INFORMATIONAL ONLY: nothing here is read by compute_incentives, technician_kpi_summary's "flagged"
-- logic, or any review column — see the standing instruction this package was built under.
--
-- 1. complaint_types.standard_minutes: nullable, master-edited in Masters > Complaint Types (ComplaintTypesTab.tsx,
--    which already master-gates writes via complaint_types_write_master — no RLS change). Per-ITEM standard times
--    (products.standard_time_minutes, spares.standard_time_minutes, 20260725100000) and the four per-TICKET-TYPE
--    defaults (settings.default_duration_*, 20260721090000) already existed; this is the finer-grained master the
--    audit found missing — per complaint type, not just per paid/warranty/amc/installation.
--
-- 2. settings.job_overrun_buffer_minutes (was the OVERRUN_BUFFER_MINUTES=5 constant in src/lib/job-overrun.ts) and
--    settings.ops_resolution_sla_hours (was the hard-coded `interval '24 hours'` inside report_ops_resolution).
--    report_ops_resolution's SAME signature and return shape otherwise; only its body now reads settings instead
--    of a literal. Default 24 preserves today's behaviour exactly until master changes it in Settings.
--
--    Review fix: report_ops_resolution kept its key literally named 'resolved_within_24h' while the window
--    behind it became configurable — an honest label needs the actual hours, not a baked-in "24". Rather than
--    rename that key (which every current reader keys off by name) the function now ALSO returns 'sla_hours' in
--    the same payload, additively, so every caller can derive its own label from the real value instead of
--    assuming 24. report_kpi_tiles is its one other SQL caller and is redefined here too, forwarding that same
--    'sla_hours' field into its own tile-13 sub-object, additively, so the KPI tile strip can show the real
--    figure as well. report_kpi_tiles' live body is the one in 20261022100000_amc_visits_unassigned_until_due.sql
--    (that migration's own "KPI: far-away AMC visits are not counted in open_tickets (live body, one added
--    condition)" redefines the whole function), NOT the earlier 20261017110000 copy it superseded — the starting
--    point here is the later, live one.
--
-- 3. report_performance_efficiency(p_from, p_to): a NEW, separate RPC — report_performance itself is NOT edited.
--    For each technician's timed visits in range (same population as report_performance's own `jobsDone`/
--    `avgCompletionMinutes`: org-scoped, not public._visit_is_test(sv.id), timer_start in range — matched against
--    report_performance's LATEST body in 20261016110000_test_customer_flag.sql, not the earlier
--    20261009120000 copy, which predates the test-customer exclusion), sums actual minutes (timer_end -
--    timer_start) against a resolved "standard" minutes figure (the ticket's complaint_types.standard_minutes if
--    set, else the ticket type's settings.default_duration_* default) and returns a percentage. A visit whose
--    standard cannot be resolved at all is excluded from BOTH sums, not counted as 0 — it would otherwise
--    silently drag the percentage down for a technician who did nothing wrong.

alter table public.complaint_types
  add column standard_minutes integer check (standard_minutes is null or standard_minutes > 0);

alter table public.settings
  add column job_overrun_buffer_minutes integer not null default 5 check (job_overrun_buffer_minutes >= 0),
  add column ops_resolution_sla_hours integer not null default 24 check (ops_resolution_sla_hours > 0);

comment on column public.settings.job_overrun_buffer_minutes is
  'Minutes of grace after a job''s allowed duration before the overrun alert fires (lib/job-overrun.ts). Was a hard-coded constant.';
comment on column public.settings.ops_resolution_sla_hours is
  'Hours within which a completed ticket counts as "resolved on time" for the ops-resolution KPI. Was a hard-coded 24h.';

-- Same signature and return shape as the existing definition; only the literal `interval '24 hours'` becomes a
-- per-org setting. report_kpi_tiles and the amc-visits migration call this by name with no argument change needed.
create or replace function public.report_ops_resolution(p_from date, p_to date)
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
  v_sla_hours integer;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_ops_resolution: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);
  select coalesce(s.ops_resolution_sla_hours, 24) into v_sla_hours from public.settings s where s.org_id = v_org;
  v_sla_hours := coalesce(v_sla_hours, 24);

  select jsonb_build_object(
    'resolved_within_24h', count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval),
    'total_completed', count(*),
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval) * 100.0 / count(*), 1) end,
    'sla_hours', v_sla_hours
  ) into v_result
  from public.service_tickets t
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$$;

create or replace function public.report_performance_efficiency(p_from date, p_to date)
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
    raise exception 'report_performance_efficiency: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with vis as (
    select sv.technician_id,
           greatest(0, round(extract(epoch from (sv.timer_end - sv.timer_start)) / 60)) as actual_minutes,
           coalesce(
             ct.standard_minutes,
             case st.type
               when 'paid' then s.default_duration_paid_minutes
               when 'warranty' then s.default_duration_warranty_minutes
               when 'amc' then s.default_duration_amc_minutes
               when 'installation' then s.default_duration_installation_minutes
             end
           ) as standard_minutes
    from public.service_visits sv
    join public.service_tickets st on st.id = sv.ticket_id
    join public.settings s on s.org_id = v_org
    left join public.complaint_types ct on ct.id = st.complaint_type_id
    where sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
      and sv.timer_start is not null and sv.timer_end is not null
  ),
  agg as (
    select technician_id, sum(standard_minutes) as std_sum, sum(actual_minutes) as act_sum, count(*) as n
    from vis
    where standard_minutes is not null
    group by technician_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.technician_id,
      'efficiency_percent', case when a.act_sum > 0 then round(a.std_sum * 100.0 / a.act_sum, 1) end,
      'efficiency_sample_count', a.n
    )), '[]'::jsonb)
  into v_result
  from agg a;
  return v_result;
end;
$$;
revoke all on function public.report_performance_efficiency(date, date) from public, anon;
grant execute on function public.report_performance_efficiency(date, date) to authenticated;

-- report_kpi_tiles (review fix): its live body, unchanged except tile 13 now also carries 'sla_hours' through from
-- report_ops_resolution's own newly-added field, additively — every other line is byte-identical to the live function.
CREATE OR REPLACE FUNCTION public.report_kpi_tiles(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();                    -- raises unless an active master / operation_admin / sales_admin
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

  -- ── sales group ────────────────────────────────────────────────────────────────────────────────────────────────────
  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      -- line revenue of the window's counter-sale (class sales) invoices, by item type
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
      -- tile 3, live: every unpaid or part-paid invoice of a non-test customer, whatever its date
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      -- tile 7. product + spare + gst_and_adjustments = the whole "sales" class; the five streams add up to invoiced.total
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      -- tile 8
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    -- tiles 9, 10 (composed)
    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    -- tile 16 (composed)
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

  -- ── service group ──────────────────────────────────────────────────────────────────────────────────────────────────
  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);
    select jsonb_build_object(
      -- tile 12, live
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      -- tile 13 (review fix: 'sla_hours' now carried through additively, so the tile strip can say the real figure)
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent',
        'sla_hours', v_ops_res->'sla_hours'),
      -- tile 14
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      -- tile 15, live counts + the window's AMC revenue
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

  -- ── money-out group (master only) ─────────────────────────────────────────────────────────────────────────────────
  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to;

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
      -- tile 4
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase')),
      -- tile 5: cash basis (Q1)
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      -- tile 6
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
    'sales', v_sales,          -- null for a caller who may not see it
    'service', v_service,
    'money_out', v_money);
end;
$function$;
