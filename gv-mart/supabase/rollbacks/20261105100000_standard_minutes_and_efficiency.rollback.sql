-- Rollback for 20261105100000_standard_minutes_and_efficiency.sql
drop function if exists public.report_performance_efficiency(date, date);

-- restore report_ops_resolution to its definition in 20261016110000_test_customer_flag.sql (hard-coded 24h,
-- is_test_customer exclusion kept — that exclusion predates this package and is not part of this rollback)
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
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$$;

alter table public.settings
  drop column if exists ops_resolution_sla_hours,
  drop column if exists job_overrun_buffer_minutes;

alter table public.complaint_types drop column if exists standard_minutes;
