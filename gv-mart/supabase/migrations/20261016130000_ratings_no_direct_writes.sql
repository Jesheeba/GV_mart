-- ratings: close the direct-write hole (2026-10-16) - batch-2 item 6, first small fix.
--
-- Found: policy ratings_write_own_technician is FOR ALL, so a technician could INSERT/UPDATE the rating row of one of their own
-- visits directly (stars, review, google_review_clicked = true) without going through submit_rating /
-- mark_google_review_clicked; ratings_write_ops did the same for ops staff. google_review_clicked drives the 'review' incentive
-- (compute_incentives), the review-time allowance and the KPIs, and stars drive averages and reward candidates.
--
-- Fix: nobody writes ratings directly any more.
--   * the two FOR ALL write policies are dropped; the technician keeps SELECT on own visits (new select-only policy), staff keep
--     ratings_select_staff, customers keep ratings_select_own_customer;
--   * INSERT/UPDATE/DELETE/TRUNCATE are revoked from anon/authenticated (belt and braces: no policy can re-open it by accident);
--   * every legitimate writer already is SECURITY DEFINER (submit_rating, submit_customer_rating) or service_role. The one
--     exception, mark_google_review_clicked, was SECURITY INVOKER and relied on that write policy: it becomes SECURITY DEFINER
--     with its existing ownership check plus an organisation check, and is no longer executable by anon/PUBLIC.
-- No data is changed. Behaviour for the app is identical (it only ever called the RPCs).

drop policy if exists ratings_write_own_technician on public.ratings;
drop policy if exists ratings_write_ops on public.ratings;

create policy ratings_select_own_technician on public.ratings for select
  using (
    exists (select 1 from public.service_visits v where v.id = ratings.visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );

revoke insert, update, delete, truncate on public.ratings from public, anon, authenticated;

create or replace function public.mark_google_review_clicked(p_org_id uuid, p_visit_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'mark_google_review_clicked: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'mark_google_review_clicked: org mismatch';
  end if;

  update public.ratings r
  set google_review_clicked = true, updated_at = now()
  from public.service_visits v
  where r.visit_id = v.id
    and r.visit_id = p_visit_id
    and r.org_id = p_org_id
    and v.technician_id = v_tech_id;

  if not found then
    raise exception 'mark_google_review_clicked: no rating found for visit % owned by calling technician', p_visit_id;
  end if;
end;
$function$;

revoke execute on function public.mark_google_review_clicked(uuid, uuid) from public, anon;
grant execute on function public.mark_google_review_clicked(uuid, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
