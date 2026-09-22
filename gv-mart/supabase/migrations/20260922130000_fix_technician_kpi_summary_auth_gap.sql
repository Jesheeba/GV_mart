-- Bug found during live-testing 20260922120000: technician_kpi_summary was
-- `security definer` but never checked WHO was calling it — an anon-key
-- client with no session at all could call it directly and read any
-- technician's avg call value / referral / review counts by guessing org and
-- technician ids. log_technician_google_review already gated correctly
-- (current_technician_id() check); this one didn't. Same guard shape as the
-- is_staff()-gated RLS policies (20260701091300_rls.sql) — this is an
-- admin-only aggregate, called from TechnicianDetailPage.tsx, not something
-- a technician or anon caller should ever read directly.
create or replace function public.technician_kpi_summary(
  p_org_id uuid,
  p_technician_id uuid
)
returns table (
  avg_call_value numeric,
  total_referrals integer,
  total_reviews integer,
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
    v_visit_count,
    case when v_visit_count > 0 then round(v_review_count::numeric / v_visit_count * 100, 1) else 0 end,
    v_visit_count >= v_min_visits
      and v_visit_count > 0
      and (v_review_count::numeric / v_visit_count * 100) >= v_threshold;
end;
$$;
