-- Reports correctness, migration 2 of 3: report_coverage (warranty / AMC / rental coverage by IST
-- month + installation rates). Additive; conventions as in 20261009100000.
--
-- Differences from the browser version it replaces (both deliberate):
--   * months and the visit month buckets are IST months (the browser used the viewer's own timezone);
--   * a rental's returned_at is compared as an IST date (the browser sliced the UTC string).
-- Kept as before: at most the newest 36 months of the range are returned (truncated = true when more),
-- months_count in the installation rates is capped the same way (and is at least 1).

create or replace function public.report_coverage(p_from date, p_to date)
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
        where sv.org_id = v_org and t.type = 'warranty'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as w_visits,
      (select count(*) from public.warranties w where w.org_id = v_org and w.start_date <= m.me and w.expiry_date >= m.ms) as w_active,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'amc'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as a_visits,
      (select count(*) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and c.expiry_date >= m.ms) as a_active,
      (select coalesce(sum(coalesce(p.price_per_year, p.price / greatest(p.years, 1)) / 12), 0) from public.amc_contracts c join public.amc_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and c.expiry_date >= m.ms) as a_value,
      (select count(*) from public.service_visits sv join public.service_tickets t on t.id = sv.ticket_id
        where sv.org_id = v_org and t.type = 'rental'
          and sv.timer_start >= public._report_ist_start(m.ms) and sv.timer_start < public._report_ist_start(m.me + 1)) as r_visits,
      (select count(*) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_active,
      (select coalesce(sum(p.monthly_rate), 0) from public.rental_contracts c join public.rental_plans p on p.id = c.plan_id
        where c.org_id = v_org and c.start_date <= m.me and (c.returned_at is null or (c.returned_at at time zone 'Asia/Kolkata')::date >= m.ms)) as r_value
    from m
  ),
  inst as (
    select il.technician_id, sum(il.qty)::bigint as qty
    from public.installations_logged il
    where il.org_id = v_org and il.created_at >= v_from and il.created_at < v_to
    group by il.technician_id
  ),
  vis as (
    select sv.technician_id, count(*) as cnt
    from public.service_visits sv
    where sv.org_id = v_org and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  agg as (
    select
      (select coalesce(sum(qty), 0) from inst) as installs,
      (select coalesce(sum(ii.qty), 0) from public.invoice_items ii
        where ii.org_id = v_org and ii.item_type = 'product' and ii.created_at >= v_from and ii.created_at < v_to) as units_sold,
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
$$;
revoke all on function public.report_coverage(date, date) from public, anon;
grant execute on function public.report_coverage(date, date) to authenticated;

notify pgrst, 'reload schema';
