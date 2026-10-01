-- Tier promotion: paid-earning helper, eligibility detector (service-role,
-- called by wa-scheduled-tasks), progress read for the technician page, and
-- approve/dismiss RPCs (master).

-- Paid revenue for one technician since p_since. Same paid-only definition as
-- technician_kpi_summary.avg_call_value (completed ticket -> invoice with
-- payment_status = 'paid'), summed instead of averaged. Internal: no direct
-- client grant (RLS-bypassing security definer), reached via the RPCs below.
create or replace function public._technician_paid_earning(
  p_org_id uuid,
  p_technician_id uuid,
  p_since timestamptz
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(v.service_charge), 0)::numeric(12, 2)
  from public.service_visits v
  join public.service_tickets st on st.id = v.ticket_id
  join public.invoices i on i.id = st.invoice_id
  where v.org_id = p_org_id
    and v.technician_id = p_technician_id
    and st.status = 'completed'
    and v.timer_end is not null
    and v.timer_end >= p_since
    and i.org_id = p_org_id
    and i.payment_status = 'paid';
$$;

revoke execute on function public._technician_paid_earning(uuid, uuid, timestamptz) from public, anon, authenticated;

-- Start of the trailing window: required_months back from now, but never
-- before the technician existed ("fewer than required_months of history:
-- window is simply since technician creation").
create or replace function public._tier_window_start(p_created_at timestamptz, p_months int)
returns timestamptz
language sql
stable
as $$
  select greatest(p_created_at, now() - make_interval(months => p_months));
$$;

revoke execute on function public._tier_window_start(timestamptz, int) from public, anon, authenticated;

-- Detector. For every active technician below the top tier, compares trailing
-- paid earning against the NEXT-ranked tier's requirement and raises one
-- pending eligibility row + one master notification. Idempotent per tick: the
-- partial unique index blocks a second pending row; a dismissal suppresses
-- re-flagging for 30 days (otherwise a dismiss would be undone by the very
-- next run, since the earning is still over the threshold). Returns the
-- number of new eligibility rows.
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
      p_org_id, v_tech.id, public._tier_window_start(v_tech.created_at, v_target.required_months)
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

revoke execute on function public.check_tier_promotion_eligibility(uuid) from public, anon, authenticated;
grant execute on function public.check_tier_promotion_eligibility(uuid) to service_role;

-- Progress toward the next tier, shown on the technician page even before the
-- threshold is hit. next_* are null at the top tier or when the next tier has
-- no requirement set.
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
        v_tech.org_id, v_tech.id, public._tier_window_start(v_tech.created_at, v_next.required_months))
    end;
end;
$$;

revoke execute on function public.technician_tier_progress(uuid) from public, anon;
grant execute on function public.technician_tier_progress(uuid) to authenticated;

create or replace function public.approve_tier_promotion(p_eligibility_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_elig public.tier_promotion_eligibility;
  v_old_tier uuid;
begin
  if not public.is_master() then
    raise exception 'approve_tier_promotion: master role required';
  end if;

  -- State-flip-as-lock (same idiom as approve_purchase_order): only one
  -- concurrent approve/dismiss can move the row out of 'pending'.
  update public.tier_promotion_eligibility
  set status = 'approved', decided_by = auth.uid(), decided_at = now()
  where id = p_eligibility_id and status = 'pending' and org_id = public.current_org_id()
  returning * into v_elig;
  if v_elig.id is null then
    raise exception 'approve_tier_promotion: eligibility % not found or already decided', p_eligibility_id;
  end if;

  select tier_id into v_old_tier from public.technicians where id = v_elig.technician_id for update;
  update public.technicians set tier_id = v_elig.target_tier_id where id = v_elig.technician_id;

  insert into public.tier_promotion_history (org_id, technician_id, old_tier_id, new_tier_id, approved_by)
  values (v_elig.org_id, v_elig.technician_id, v_old_tier, v_elig.target_tier_id, auth.uid());
end;
$$;

create or replace function public.dismiss_tier_promotion(p_eligibility_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public.is_master() then
    raise exception 'dismiss_tier_promotion: master role required';
  end if;
  update public.tier_promotion_eligibility
  set status = 'dismissed', decided_by = auth.uid(), decided_at = now()
  where id = p_eligibility_id and status = 'pending' and org_id = public.current_org_id()
  returning id into v_id;
  if v_id is null then
    raise exception 'dismiss_tier_promotion: eligibility % not found or already decided', p_eligibility_id;
  end if;
end;
$$;

revoke execute on function public.approve_tier_promotion(uuid), public.dismiss_tier_promotion(uuid) from public, anon;
grant execute on function public.approve_tier_promotion(uuid), public.dismiss_tier_promotion(uuid) to authenticated;
