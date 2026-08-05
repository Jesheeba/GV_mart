-- Client rewards spec (4 criteria) — reward_candidates() rewrite.
--
-- v2.2's ADM-26 reward_candidates() (20260702200200_hr_functions.sql) only
-- covered 3 categories, and its attendance rule was "zero late days this
-- month" rather than the client's actual spec ("full attendance / no leave"
-- + "total lateness within 3 hours/month"). This redefines the function to:
--   1. attendance: full attendance (a row on every day the org actually
--      operated this month — see org_days CTE) AND total late hours <= 3,
--      winner = lowest late hours among those who clear both bars.
--   2. highest_revenue: now technician_attributed_revenue() (service) PLUS
--      technician_attributed_sales() (product/spare/AMC via sold_by), so
--      "revenue" isn't service-only. Threshold unchanged (>= 150000).
--   3. highest_review: unchanged — already >= 51 (client said "above 50").
--   4. highest_referral (new): technician_finder_conversions() (finder-credit
--      plumbing, now fed by Sales/Service/AMC too per
--      20260804150000_referral_capture_functions.sql), threshold >= 20,
--      winner = highest count — matches "Highest Referral ... qty 20
--      reached" exactly.
create or replace function public.reward_candidates(
  p_org_id uuid,
  p_period date
)
returns table (
  category reward_category,
  technician_id uuid,
  metric numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
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
$$;

grant execute on function public.reward_candidates(uuid, date) to authenticated;
