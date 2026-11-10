-- Rollback for 20261106100000_technician_leave_request.sql.
-- Restores reward_candidates() to the body from 20261016110000_test_customer_flag.sql (no
-- protected-leave exclusion, no per-day coverage, no minimum-present ratio), drops every new
-- function, drops the link columns on technician_availability, drops the audit trigger and the
-- new table, and drops the leave_notice_days and attendance_reward_min_present_ratio settings.
-- Refuses outright if technician_leave_requests has any row at all -- this rollback has no
-- migration path to preserve real request history, so it will not silently drop it.
-- Rows already written into technician_availability by decide_technician_leave (status='leave')
-- are left exactly as they are — they are ordinary leave rows now, same as any admin-direct entry,
-- and this rollback does not delete calendar data.

-- ── refuse if any real request exists -- this rollback has no migration path for that data,
--    so dropping the table under it would silently destroy it. Checked FIRST, before any other
--    drop or replace, so a refusal here leaves everything completely untouched. ─────────────────
do $$
begin
  if exists (select 1 from public.technician_leave_requests limit 1) then
    raise exception 'rollback refused: technician_leave_requests has % row(s) -- this rollback does not know how to preserve them',
      (select count(*) from public.technician_leave_requests);
  end if;
end;
$$;

-- ── reward_candidates: back to the live (pre-feature) body, unchanged from
--    20261016110000_test_customer_flag.sql ──────────────────────────────────────────────────────
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

-- ── drop the new functions ──────────────────────────────────────────────────────────────────
drop function if exists public.technician_protected_leave_days(uuid, uuid, date, date);
drop function if exists public.technician_assigned_visits_in_range(uuid, date, date);
drop function if exists public.decide_technician_leave(uuid, text, text);
drop function if exists public.cancel_technician_leave(uuid);
drop function if exists public.request_technician_leave(date, date, text);
drop function if exists public._leave_request_is_protected(timestamptz, date, integer);

-- ── drop the link columns on the existing calendar table ──────────────────────────────────────
alter table public.technician_availability
  drop column if exists leave_request_id,
  drop column if exists protected;

-- ── drop the audit trigger, then the request table (the trigger drops with the table too; kept
--    explicit per the deploy checklist) ───────────────────────────────────────────────────────
drop trigger if exists audit_technician_leave_requests on public.technician_leave_requests;
drop table if exists public.technician_leave_requests;

-- ── drop the settings ───────────────────────────────────────────────────────────────────────
alter table public.settings drop column if exists leave_notice_days;
alter table public.settings drop column if exists attendance_reward_min_present_ratio;

notify pgrst, 'reload schema';
