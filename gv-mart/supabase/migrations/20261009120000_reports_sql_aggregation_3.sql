-- Reports correctness, migration 3 of 3: report_performance, report_ops_resolution, report_feedback
-- and the two Accounts aggregates (salary by staff, expenses year over year).
-- Additive; conventions as in 20261009100000 (plain dates in, IST half-open windows, definer/stable,
-- authenticated only).
--
-- Behaviour kept from the browser versions (same numbers on the same data):
--   * performance: ratings are attributed through the visit's timer_start (not the rating's own date);
--     productivity is jobs / on-duty hours (attendance days with both check-in and check-out);
--     "on time" = visit without needs_revisit.
-- Deliberate changes:
--   * performance: a lead owner with no visits now shows their real name instead of "—";
--   * feedback: the trend groups by IST day (the browser grouped by the UTC date of created_at);
--   * year over year: "today" and the year-to-date cut-off are IST, and the cut-off is the exact
--     day-of-year of today (the browser's calculation ran about a day ahead).
-- Expenses are master-only data (RLS): salary_by_staff returns [] and year_over_year returns zeros
-- for anyone else, exactly what the old queries returned under RLS.

-- ── report_performance ───────────────────────────────────────────────────
create or replace function public.report_performance(p_from date, p_to date)
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
    where sv.org_id = v_org and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  rat as (
    select sv.technician_id, sum(r.stars) as star_sum, count(*) as cnt
    from public.ratings r
    join public.service_visits sv on sv.id = r.visit_id
    where r.org_id = v_org and sv.org_id = v_org and sv.timer_start >= v_from and sv.timer_start < v_to
    group by sv.technician_id
  ),
  led as (
    select l.owner_id as technician_id, count(*) as total, count(*) filter (where l.status = 'won') as won
    from public.leads l
    where l.org_id = v_org and l.owner_id is not null and l.created_at >= v_from and l.created_at < v_to
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
    where il.org_id = v_org and il.created_at >= v_from and il.created_at < v_to
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
$$;
revoke all on function public.report_performance(date, date) from public, anon;
grant execute on function public.report_performance(date, date) to authenticated;

-- ── report_ops_resolution ────────────────────────────────────────────────
-- % of tickets created in the window that were completed within 24h of creation.
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
  where t.org_id = v_org and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$$;
revoke all on function public.report_ops_resolution(date, date) from public, anon;
grant execute on function public.report_ops_resolution(date, date) to authenticated;

-- ── report_feedback ──────────────────────────────────────────────────────
-- The low-rating reason is not a column on ratings: submit_rating() writes a notifications row
-- (type 'low_rating', ref_id = rating id) whose body ends in "Reason: ...". Recovered the same way here.
create or replace function public.report_feedback(p_from date, p_to date)
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
    raise exception 'report_feedback: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with rt as (
    select r.id, r.stars, r.review, r.created_at, r.visit_id
    from public.ratings r
    join public.service_visits sv on sv.id = r.visit_id and sv.org_id = v_org
    where r.org_id = v_org and r.created_at >= v_from and r.created_at < v_to
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
$$;
revoke all on function public.report_feedback(date, date) from public, anon;
grant execute on function public.report_feedback(date, date) to authenticated;

-- ── report_expenses_salary_by_staff (Accounts) ───────────────────────────
create or replace function public.report_expenses_salary_by_staff(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_expenses_salary_by_staff: p_from and p_to are required';
  end if;
  if not coalesce(public.is_master(), false) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.staff_id, 'staff_name', s.name, 'total', s.total) order by s.total desc, s.name, s.staff_id), '[]'::jsonb)
  into v_result
  from (
    select e.staff_id, coalesce(p.full_name, '—') as name, sum(e.amount) as total
    from public.expenses e
    left join public.profiles p on p.id = e.staff_id
    where e.org_id = v_org and e.category = 'salary' and e.staff_id is not null and e.date >= p_from and e.date <= p_to
    group by e.staff_id, p.full_name
  ) s;
  return v_result;
end;
$$;
revoke all on function public.report_expenses_salary_by_staff(date, date) from public, anon;
grant execute on function public.report_expenses_salary_by_staff(date, date) to authenticated;

-- ── report_expenses_year_over_year (Accounts) ────────────────────────────
-- One row per year, current IST year first, going back p_years_back years (0..20). ytd_comparable_total
-- is the sum up to today's day-of-year, so a part-complete current year compares fairly with whole years.
create or replace function public.report_expenses_year_over_year(p_years_back integer default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_back integer := least(greatest(coalesce(p_years_back, 3), 0), 20);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_cy integer := extract(year from v_today)::integer;
  v_doy integer := extract(doy from v_today)::integer;
  v_master boolean := coalesce(public.is_master(), false);
  v_result jsonb;
begin
  with ex as (
    select e.category, e.amount, e.date, extract(year from e.date)::integer as yr, extract(doy from e.date)::integer as doy
    from public.expenses e
    where v_master and e.org_id = v_org and e.date >= make_date(v_cy - v_back, 1, 1)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'year', y.yr,
      'full_year_total', coalesce((select sum(amount) from ex where ex.yr = y.yr), 0),
      'ytd_comparable_total', coalesce((select sum(amount) from ex where ex.yr = y.yr and ex.doy <= v_doy), 0),
      'by_category', coalesce((select jsonb_agg(jsonb_build_object('category', c.category, 'amount', c.amount) order by c.amount desc, c.category)
                               from (select category, sum(amount) as amount from ex where ex.yr = y.yr group by category) c), '[]'::jsonb)
    ) order by y.yr desc), '[]'::jsonb)
  into v_result
  from generate_series(v_cy - v_back, v_cy) y(yr);
  return v_result;
end;
$$;
revoke all on function public.report_expenses_year_over_year(integer) from public, anon;
grant execute on function public.report_expenses_year_over_year(integer) to authenticated;

notify pgrst, 'reload schema';
