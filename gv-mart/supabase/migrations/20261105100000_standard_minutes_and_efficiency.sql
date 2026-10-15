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
--    report_ops_resolution is redefined with the SAME signature and return shape — its two existing SQL callers
--    (report_kpi_tiles, the amc-visits migration) are untouched; only its body now reads settings instead of a
--    literal. Default 24 preserves today's behaviour exactly until master changes it in Settings.
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
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval) * 100.0 / count(*), 1) end
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
