-- Two logic fixes to tier promotion (20261001120000):
--
-- 1. The trailing earning window ignored when a technician was last promoted,
--    so earnings that already counted toward the promotion to tier N could
--    immediately qualify them for tier N+1. The window now starts at the later
--    of (technician creation / N months back) and the last promotion.
--
-- 2. approve_tier_promotion applied the flagged target tier without checking
--    the technician was still on the tier below it. If a master overrode the
--    tier between detection and approval, approving would silently move them
--    to the wrong tier (down, or skipping one). It now rejects with a clear
--    error and leaves the eligibility row pending (the raise rolls back the
--    claim), so it can be dismissed.

-- New 3-arg window start; the 2-arg version is dropped below once its
-- callers are redefined.
create or replace function public._tier_window_start(
  p_technician_id uuid,
  p_created_at timestamptz,
  p_months int
)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select greatest(
    p_created_at,
    now() - make_interval(months => p_months),
    coalesce(
      (select max(h.promoted_at) from public.tier_promotion_history h where h.technician_id = p_technician_id),
      '-infinity'::timestamptz
    )
  );
$$;

revoke execute on function public._tier_window_start(uuid, timestamptz, int) from public, anon, authenticated;

create or replace function public.check_tier_promotion_eligibility(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech record;
  v_target public.technician_tiers;
  v_current_rank int;
  v_earning numeric(12, 2);
  v_elig_id uuid;
  v_created integer := 0;
begin
  for v_tech in
    select t.id, t.tier_id, t.created_at, coalesce(p.full_name, 'A technician') as full_name
    from public.technicians t
    left join public.profiles p on p.id = t.profile_id
    where t.org_id = p_org_id and t.is_active
  loop
    select rank into v_current_rank from public.technician_tiers where id = v_tech.tier_id;
    if v_current_rank is null then
      select rank into v_current_rank from public.technician_tiers where org_id = p_org_id and rank = 1;
    end if;
    continue when v_current_rank is null;

    select * into v_target
    from public.technician_tiers
    where org_id = p_org_id and rank = v_current_rank + 1;
    continue when v_target.id is null
      or v_target.required_earning is null
      or v_target.required_months is null;

    if exists (
      select 1 from public.tier_promotion_eligibility e
      where e.technician_id = v_tech.id and e.target_tier_id = v_target.id
        and (e.status = 'pending' or (e.status = 'dismissed' and e.decided_at > now() - interval '30 days'))
    ) then
      continue;
    end if;

    v_earning := public._technician_paid_earning(
      p_org_id, v_tech.id, public._tier_window_start(v_tech.id, v_tech.created_at, v_target.required_months)
    );
    continue when v_earning < v_target.required_earning;

    insert into public.tier_promotion_eligibility (org_id, technician_id, target_tier_id, earning_snapshot, window_months)
    values (p_org_id, v_tech.id, v_target.id, v_earning, v_target.required_months)
    on conflict do nothing
    returning id into v_elig_id;
    continue when v_elig_id is null;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'master', 'tier_promotion_eligible', 'Technician eligible for promotion',
      format('%s has earned ₹%s in the last %s month(s) and is eligible for promotion to %s.',
             v_tech.full_name, v_earning, v_target.required_months, v_target.name),
      v_elig_id
    );
    v_created := v_created + 1;
  end loop;
  return v_created;
end;
$$;

create or replace function public.technician_tier_progress(p_technician_id uuid)
returns table (
  current_tier_id uuid,
  current_tier_name text,
  next_tier_id uuid,
  next_tier_name text,
  required_earning numeric,
  required_months integer,
  earning numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tech public.technicians;
  v_cur public.technician_tiers;
  v_next public.technician_tiers;
begin
  select * into v_tech from public.technicians where id = p_technician_id;
  if v_tech.id is null or v_tech.org_id is distinct from public.current_org_id() or not public.is_staff() then
    raise exception 'technician_tier_progress: not permitted';
  end if;

  select * into v_cur from public.technician_tiers where id = v_tech.tier_id;
  if v_cur.id is null then
    select * into v_cur from public.technician_tiers where org_id = v_tech.org_id and rank = 1;
  end if;
  if v_cur.id is not null then
    select * into v_next from public.technician_tiers where org_id = v_tech.org_id and rank = v_cur.rank + 1;
  end if;

  return query select
    v_cur.id, v_cur.name,
    v_next.id, v_next.name, v_next.required_earning, v_next.required_months,
    case when v_next.id is not null and v_next.required_months is not null
      then public._technician_paid_earning(
        v_tech.org_id, v_tech.id,
        public._tier_window_start(v_tech.id, v_tech.created_at, v_next.required_months))
    end;
end;
$$;

drop function public._tier_window_start(timestamptz, int);

create or replace function public.approve_tier_promotion(p_eligibility_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_elig public.tier_promotion_eligibility;
  v_target public.technician_tiers;
  v_old_tier uuid;
  v_old_rank int;
begin
  if not public.is_master() then
    raise exception 'approve_tier_promotion: master role required';
  end if;

  -- State-flip-as-lock (same idiom as approve_purchase_order): only one
  -- concurrent approve/dismiss can move the row out of 'pending'. Any raise
  -- below rolls this back, leaving the row pending.
  update public.tier_promotion_eligibility
  set status = 'approved', decided_by = auth.uid(), decided_at = now()
  where id = p_eligibility_id and status = 'pending' and org_id = public.current_org_id()
  returning * into v_elig;
  if v_elig.id is null then
    raise exception 'approve_tier_promotion: eligibility % not found or already decided', p_eligibility_id;
  end if;

  select tier_id into v_old_tier from public.technicians where id = v_elig.technician_id for update;

  select * into v_target from public.technician_tiers where id = v_elig.target_tier_id;

  -- Same current-rank rule as the detector: a null tier_id means rank 1.
  select rank into v_old_rank from public.technician_tiers where id = v_old_tier;
  if v_old_rank is null then
    select rank into v_old_rank from public.technician_tiers where org_id = v_elig.org_id and rank = 1;
  end if;

  if v_old_rank is distinct from v_target.rank - 1 then
    raise exception 'approve_tier_promotion: technician is no longer on the tier below %; their tier changed after this promotion was flagged. Dismiss this one and let eligibility be re-checked.', v_target.name;
  end if;

  update public.technicians set tier_id = v_elig.target_tier_id where id = v_elig.technician_id;

  insert into public.tier_promotion_history (org_id, technician_id, old_tier_id, new_tier_id, approved_by)
  values (v_elig.org_id, v_elig.technician_id, v_old_tier, v_elig.target_tier_id, auth.uid());
end;
$$;
