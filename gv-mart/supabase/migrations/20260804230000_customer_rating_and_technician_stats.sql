-- Premium Live Tracking (customer app) — Service Completed screen needs two
-- new capabilities that don't exist today: (1) the customer submitting a
-- rating themselves (today `ratings` is only writable by the technician's
-- own handoff flow, via ratings_write_own_technician — see submit_rating in
-- 20260702120000_technician_phase7_functions.sql, the template this
-- mirrors) and (2) a technician's public aggregate stats (avg rating,
-- completed job count) for the tracking screen's technician card — today
-- ratings_select_own_customer only lets a customer read ratings tied to
-- their OWN ticket, not a technician's full history, so no client-side
-- query can produce "4.9 stars, 1,842 services completed".

create or replace function public.submit_customer_rating(
  p_org_id uuid,
  p_visit_id uuid,
  p_stars numeric,
  p_review text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_rating_id uuid;
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'submit_customer_rating: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'submit_customer_rating: org mismatch';
  end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then
    raise exception 'submit_customer_rating: stars must be between 1 and 5';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'submit_customer_rating: visit % not found', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket.id is null or v_ticket.customer_id is distinct from v_customer_id then
    raise exception 'submit_customer_rating: visit % does not belong to the calling customer', p_visit_id;
  end if;
  if v_visit.timer_end is null then
    raise exception 'submit_customer_rating: visit % is not completed yet', p_visit_id;
  end if;
  if exists (select 1 from public.ratings where visit_id = p_visit_id) then
    raise exception 'submit_customer_rating: visit % has already been rated', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  insert into public.ratings (org_id, visit_id, stars, review)
  values (p_org_id, p_visit_id, p_stars, nullif(btrim(coalesce(p_review, '')), ''))
  returning id into v_rating_id;

  -- Same v2.2 §6.7 threshold behavior as submit_rating: below the admin-set
  -- review-link threshold, notify operation admin instead of surfacing a
  -- public review-link prompt.
  if v_settings is not null and p_stars < v_settings.review_link_min_stars then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'low_rating', 'Low customer rating received',
      format('A %s-star rating was recorded by the customer.', p_stars),
      v_rating_id
    );
  end if;

  return v_rating_id;
end;
$$;

grant execute on function public.submit_customer_rating(uuid, uuid, numeric, text) to authenticated;

-- Aggregate-only, no per-customer data leak: avg rating + completed job
-- count for any technician in the caller's own org. Any authenticated
-- staff/technician/customer role may call this (it's the same class of
-- information technicians.list already shows admins) — cross-org lookups
-- are blocked by the org_id check.
create or replace function public.get_technician_public_stats(p_technician_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_avg_rating numeric;
  v_completed_count integer;
begin
  select org_id into v_org_id from public.technicians where id = p_technician_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    raise exception 'get_technician_public_stats: technician % not found', p_technician_id;
  end if;

  select round(avg(r.stars), 1) into v_avg_rating
  from public.ratings r
  join public.service_visits sv on sv.id = r.visit_id
  where sv.technician_id = p_technician_id;

  select count(*) into v_completed_count
  from public.service_visits sv
  where sv.technician_id = p_technician_id and sv.timer_end is not null;

  return jsonb_build_object('avg_rating', v_avg_rating, 'completed_count', v_completed_count);
end;
$$;

grant execute on function public.get_technician_public_stats(uuid) to authenticated;
