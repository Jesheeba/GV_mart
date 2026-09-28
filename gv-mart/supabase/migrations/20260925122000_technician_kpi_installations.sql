-- Technician Installation Tracking — KPI tile half. Adds a lifetime
-- total_installations count to technician_kpi_summary, same aggregation
-- horizon as total_referrals/total_reviews on that same RPC (KpisTab on
-- TechnicianDetailPage). Return columns change, so this must be a drop +
-- recreate, not a plain create-or-replace.
drop function if exists public.technician_kpi_summary(uuid, uuid);

create function public.technician_kpi_summary(
  p_org_id uuid,
  p_technician_id uuid
)
returns table (
  avg_call_value numeric,
  total_referrals integer,
  total_reviews integer,
  total_installations integer,
  completed_visit_count integer,
  review_claim_rate_percent numeric,
  flagged boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
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
    and v.timer_end is not null;

  select count(*) into v_review_count
  from public.customer_members cm
  where cm.org_id = p_org_id
    and cm.google_review_technician_id = p_technician_id
    and cm.google_review_photo_url is not null;

  select coalesce(sum(il.qty), 0) into v_install_count
  from public.installations_logged il
  where il.org_id = p_org_id
    and il.technician_id = p_technician_id;

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
$$;

grant execute on function public.technician_kpi_summary(uuid, uuid) to authenticated;
