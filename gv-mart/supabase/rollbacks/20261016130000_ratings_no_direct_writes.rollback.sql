-- Rollback for 20261016130000_ratings_no_direct_writes.sql: re-opens the direct-write policies and grants (the hole).
drop policy if exists ratings_select_own_technician on public.ratings;
create policy ratings_write_own_technician on public.ratings for all
  using (
    exists (select 1 from public.service_visits v where v.id = ratings.visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  )
  with check (
    exists (select 1 from public.service_visits v where v.id = ratings.visit_id and v.technician_id = public.current_technician_id())
    and public.current_technician_is_active()
  );
create policy ratings_write_ops on public.ratings for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
grant insert, update, delete, truncate on public.ratings to anon, authenticated;

create or replace function public.mark_google_review_clicked(p_org_id uuid, p_visit_id uuid)
returns void
language plpgsql
as $function$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'mark_google_review_clicked: caller is not a technician';
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
grant execute on function public.mark_google_review_clicked(uuid, uuid) to public, anon, authenticated, service_role;
notify pgrst, 'reload schema';
