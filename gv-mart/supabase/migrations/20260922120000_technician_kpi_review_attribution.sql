-- Technician KPI section: average call value (paid only), total referrals,
-- total Google reviews. Referrals already have everything they need
-- (leads.owner_id, technician_finder_conversions precedent) — this migration
-- only adds what's missing: (1) admin-configurable review-claim flag
-- thresholds on `settings`, matching the existing bolt-a-column-on precedent
-- (20260825160000_wa_scheduled_job_intervals.sql); (2) job/technician/photo
-- attribution columns on the existing D4 manual review log
-- (20260915120000_family_member_google_review_log.sql), which today has zero
-- link to any ticket or technician; (3) two RPCs — one that lets a
-- technician log a review claim against their OWN completed visit only
-- (mirrors submit_rating's ownership check), and one that computes the full
-- KPI summary (+ the statistical flag) server-side in one round trip.

alter table public.settings
  add column if not exists review_flag_threshold_percent numeric not null default 65
    check (review_flag_threshold_percent between 0 and 100),
  add column if not exists review_flag_min_visits integer not null default 10
    check (review_flag_min_visits > 0);

-- A review claim only counts toward a technician's KPI once a photo is
-- attached (google_review_photo_url is not null) — see log_technician_google_review
-- below, which enforces this at write time. ticket_id/technician_id are
-- denormalized onto the row (rather than requiring a join through visits)
-- purely so technician_kpi_summary can filter on them directly.
alter table public.customer_members
  add column if not exists google_review_ticket_id uuid references public.service_tickets(id),
  add column if not exists google_review_technician_id uuid references public.technicians(id),
  add column if not exists google_review_photo_url text;

-- ── log_technician_google_review ────────────────────────────────────────
-- Technician-side counterpart to the admin-only logMemberGoogleReview: logged
-- from a specific closed visit (HistoryDetailPage), so member/ticket/technician
-- are all known from context — no dropdown, no manual attribution. Ownership
-- check mirrors submit_rating (visit must belong to the calling technician).
-- Photo is mandatory here (unlike the admin path, which predates this and has
-- no job context to attach one to).
create or replace function public.log_technician_google_review(
  p_org_id uuid,
  p_visit_id uuid,
  p_member_id uuid,
  p_stars smallint,
  p_photo_url text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_member_exists boolean;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'log_technician_google_review: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'log_technician_google_review: org mismatch';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'log_technician_google_review: stars must be between 1 and 5';
  end if;
  if p_photo_url is null or btrim(p_photo_url) = '' then
    raise exception 'log_technician_google_review: photo is required';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null or v_visit.technician_id is distinct from v_tech_id then
    raise exception 'log_technician_google_review: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select exists(
    select 1 from public.customer_members cm
    join public.service_tickets st on st.customer_id = cm.customer_id
    where cm.id = p_member_id and st.id = v_visit.ticket_id and cm.org_id = p_org_id
  ) into v_member_exists;
  if not v_member_exists then
    raise exception 'log_technician_google_review: member % is not on this job''s customer', p_member_id;
  end if;

  update public.customer_members
  set google_review_stars = p_stars,
      google_review_logged_at = now(),
      google_review_ticket_id = v_visit.ticket_id,
      google_review_technician_id = v_tech_id,
      google_review_photo_url = p_photo_url
  where id = p_member_id;

  return p_member_id;
end;
$$;

grant execute on function public.log_technician_google_review(uuid, uuid, uuid, smallint, text) to authenticated;

-- ── technician_kpi_summary ───────────────────────────────────────────────
-- Lifetime-to-date, same horizon as the existing Referrals/Rewards tabs.
-- avg_call_value averages service_visits.service_charge only across visits
-- whose ticket's invoice is fully paid (payment_status = 'paid') — a
-- partially-paid job isn't counted at all until it flips to paid, per the
-- 2026-09-22 design decision. total_reviews only counts claims with a photo
-- attached (enforced at write time by log_technician_google_review, but
-- checked again here defensively). flagged uses the admin-configurable
-- settings.review_flag_threshold_percent / review_flag_min_visits — never a
-- hardcoded value, so it can be tuned without a migration.
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

grant execute on function public.technician_kpi_summary(uuid, uuid) to authenticated;
