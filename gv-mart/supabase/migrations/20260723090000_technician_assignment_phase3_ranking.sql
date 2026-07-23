-- Phase 3 of GV_Mart_Technician_Assignment_Logic_Change.md /
-- GV_Mart_Build_Order_and_Guardrails.md STEP 3: replace the rigid
-- rating-override cascade ("Logic 1/2") that used to run BEFORE the
-- filtered candidate query with a single WEIGHTED RANKING over the Phase 2
-- filtered pool. No signature change, so a plain create-or-replace is safe
-- (same reasoning as 20260721100000/20260721110000).
--
-- What used to happen (20260721110000 and earlier): if the customer's most
-- recent completed ticket's technician got >=4 stars, that exact technician
-- was hard-picked -- bypassing zone/capacity/distance entirely, only
-- checking is_on_duty + no open appointment (so a far-away or over-capacity
-- "loved" technician could still be force-picked). If <=3 stars, some OTHER
-- technician was hard-picked by highest average rating alone, again
-- bypassing distance/zone/capacity. Neither branch ever consulted the
-- Phase 2 filtered pool.
--
-- What happens now: the Phase 2 filter (zone + capacity + roster/duty +
-- no-open-appointment; skill is a deliberate no-op per G1) still runs
-- first, UNCHANGED (verbatim WHERE clause, diffed against 20260721110000
-- before writing this migration). Every technician who survives that
-- filter is a legitimate candidate; which one wins is now decided by a
-- single ORDER BY with five keys, in the order specified by the spec:
--   1. Nearest distance (bucketed -- see the inline comment at that ORDER
--      BY key for the bucket-size reasoning)
--   2. Preference tilt (soft): the customer's prior 4-5* technician, ONLY
--      if they're still in the filtered pool (far/full/wrong-zone prior
--      techs are simply absent from the candidate rows -- nothing extra
--      needed to "skip" them)
--   3. Fairness tiebreak: fewer appointments already booked that day
--      (this was already the query's second ORDER BY key -- kept as-is,
--      just renumbered in the new priority order)
--   4. Quality steer (soft): de-prioritise the customer's own prior <=3*
--      technician, then generally prefer a higher lifetime average rating
--   5. Deterministic fallback: oldest technicians.created_at (unchanged,
--      still last)
-- A technician who is far away or over capacity is never in the row set at
-- all, so preference/quality can only ever choose AMONG legitimate
-- candidates -- they can never resurrect an excluded technician. This is
-- what satisfies "preference never overrides distance when the preferred
-- tech is far" and "preference never exceeds daily capacity" from the
-- spec's Phase 3 rules section: those aren't special-cased in the ranking
-- at all, they fall out for free from ranking happening strictly AFTER
-- filtering.
--
-- The customer's prior-ticket lookup (v_prior_ticket_id / v_prior_tech_id /
-- v_prior_stars) is unchanged from Phase 1/2 -- still gated on
-- `not p_skip_rating_logic` so AMC/warranty visit-scheduling loops (which
-- pass p_skip_rating_logic => true) never apply a customer-specific
-- preference or de-prioritisation tilt, exactly as before. What changed is
-- only what's DONE with that lookup: instead of hard-picking a technician
-- outright, it now sets one of two generic soft-preference variables that
-- feed the ranking's ORDER BY:
--   - v_preferred_tech_id: the "soft-preferred technician for this
--     assignment". Deliberately named/structured generically rather than
--     inlining "customer's prior tech" directly into the ORDER BY, so a
--     second preference source can be added later without restructuring
--     the ranking -- see the one-line marker comment at ORDER BY key 2
--     below. (Build Order 6.3's enquiry-finder tilt is EXPLICITLY OUT OF
--     SCOPE for this migration -- it needs a ticket->lead linkage
--     (leads.owner_id + something like service_tickets.lead_id) that does
--     not exist anywhere in the schema yet. Confirmed via grep before
--     writing this migration. That's a separate, parallel task.)
--   - v_deprioritized_tech_id: the customer's own prior <=3* technician,
--     soft-ranked behind other similar-distance candidates rather than
--     hard-excluded (they can still win if they're clearly nearest, or if
--     no one else is close).
--
-- Return shape is byte-for-byte unchanged
-- (jsonb_build_object('assigned', true/false, ...)) -- verified against
-- src/services/service.ts's autoAssignTicket()/createComplaintTicket()
-- callers, which only ever read `assigned`, `reason_key`, `technician_id`,
-- `appointment_id` generically; nothing reads a reason_key that Logic 1/2
-- used to produce (that block never returned early / never set a
-- reason_key of its own -- it only ever set v_tech_id or left it null for
-- the candidate query below to try), so no frontend change is needed here.

create or replace function public._auto_assign_ticket_internal(
  p_ticket_id uuid,
  p_org_id uuid,
  p_skip_rating_logic boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket service_tickets;
  v_appointment appointments;
  v_addr addresses;
  v_tech_id uuid;
  v_tech_count integer;
  v_prior_ticket_id uuid;
  v_prior_tech_id uuid;
  v_prior_stars numeric(2,1);
  v_preferred_tech_id uuid;
  v_deprioritized_tech_id uuid;
  v_settings settings;
  v_sla_hours numeric;
begin
  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % not found', p_ticket_id;
  end if;

  select * into v_appointment from public.appointments
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress')
  order by created_at desc limit 1;
  if v_appointment.id is null then
    raise exception '_auto_assign_ticket_internal: ticket % has no open appointment to assign', p_ticket_id;
  end if;
  if v_appointment.technician_id is not null then
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.alreadyAssigned');
  end if;

  if v_ticket.address_id is not null then
    select * into v_addr from public.addresses where id = v_ticket.address_id;
  end if;

  -- Soft preference/quality signal (Phase 3): find the customer's most
  -- recent completed ticket's technician + the rating they got, same
  -- lookup as the old Logic 1/2, still skipped entirely for AMC/warranty
  -- visit-scheduling loops (p_skip_rating_logic => true). Unlike before,
  -- this NEVER hard-picks a technician here -- it only sets one of the two
  -- generic soft variables consumed by the ranking ORDER BY below.
  if not p_skip_rating_logic then
    select st2.id into v_prior_ticket_id
    from public.service_tickets st2
    where st2.customer_id = v_ticket.customer_id and st2.id <> p_ticket_id and st2.status = 'completed'
    order by st2.updated_at desc limit 1;

    if v_prior_ticket_id is not null then
      select sv.technician_id, r.stars into v_prior_tech_id, v_prior_stars
      from public.service_visits sv
      left join public.ratings r on r.visit_id = sv.id
      where sv.ticket_id = v_prior_ticket_id
      order by sv.timer_start desc limit 1;
    end if;

    if v_prior_stars >= 4 and v_prior_tech_id is not null then
      v_preferred_tech_id := v_prior_tech_id;
    elsif v_prior_stars is not null and v_prior_stars <= 3 and v_prior_tech_id is not null then
      v_deprioritized_tech_id := v_prior_tech_id;
    end if;
  end if;

  -- Candidate ranking: on-duty (same-day) / rostered (future-dated), hard
  -- filtered by zone + capacity (Phase 2; skill is deliberately NOT a
  -- filter here -- G1), no open appointment. WHERE clause is verbatim from
  -- 20260721110000 (diffed before writing this migration) -- Phase 3 only
  -- changes the ORDER BY. `if v_tech_id is null` is now always true (the
  -- old pre-filter hard-pick above it is gone) -- kept as a defensive guard
  -- / minimal-diff structural marker rather than removed outright, in case
  -- a future phase reintroduces an earlier short-circuit.
  if v_tech_id is null then
    select t.id into v_tech_id
    from public.technicians t
    left join lateral (
      select tl.lat, tl.lng from public.technician_locations tl
      where tl.technician_id = t.id order by tl.recorded_at desc limit 1
    ) loc on true
    where t.org_id = p_org_id
      and (
        v_appointment.scheduled_at is null
        or v_appointment.scheduled_at::date <= current_date
        or t.is_on_duty = true
      )
      and (
        v_appointment.scheduled_at is null
        or v_appointment.scheduled_at::date <= current_date
        or not exists (
          select 1 from public.technician_availability ta
          where ta.technician_id = t.id
            and ta.date = v_appointment.scheduled_at::date
            and ta.status = 'leave'
        )
      )
      and not exists (
        select 1 from public.appointments a
        where a.technician_id = t.id and a.status in ('scheduled', 'in_progress')
      )
      and (v_addr.zone is null or t.zone is null or t.zone = v_addr.zone)
      and coalesce((
        select sum(st2.estimated_duration_minutes)
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = t.id
          and a2.status in ('scheduled', 'in_progress')
          and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ), 0) + coalesce(v_ticket.estimated_duration_minutes, 0) <= t.daily_capacity_minutes
    order by
      -- 1. NEAREST DISTANCE, bucketed. Raw value is still the same `<->`
      --    Euclidean distance over (lng, lat) points as before -- this file
      --    has never applied geodesic correction, so bucketing that same
      --    raw value introduces no new precision loss versus what already
      --    existed. Bucket size: round to 2 decimal places, i.e. a ~0.01
      --    degree grid. At GV Mart's Tamil Nadu latitude band (~8-13 N),
      --    0.01 degrees of latitude is ~1.11 km and 0.01 degrees of
      --    longitude is ~1.09 km (111.32 km/deg * cos(latitude)) -- close
      --    enough to treat uniformly as "~1 km" for this purpose regardless
      --    of which direction the tech-to-address vector points. Reasoning
      --    for choosing ~1 km specifically: it's tight enough that a
      --    genuinely nearer stranger a few km away still wins outright (a
      --    different bucket), but loose enough that two technicians in the
      --    same neighbourhood -- where real-world travel time is dominated
      --    by traffic/road layout, not GPS metres -- are treated as
      --    "roughly tied" so keys 2-4 below get a real chance to act as
      --    tiebreakers instead of raw distance deciding everything down to
      --    metres of noise. NULLs (no last-known location, or no address
      --    lat/lng) sort last, same as before.
      round(
        (case when loc.lat is not null and v_addr.lat is not null and v_addr.lng is not null
          then point(loc.lng, loc.lat) <-> point(v_addr.lng, v_addr.lat)
          else null
        end)::numeric,
        2
      ) asc nulls last,
      -- 2. PREFERENCE TILT (soft): within the same distance bucket, prefer
      --    the soft-preferred technician for this assignment, if any (see
      --    v_preferred_tech_id above -- null whenever there's no prior
      --    4-5* technician, p_skip_rating_logic was passed, or the prior
      --    technician didn't survive the Phase 2 filter, in which case they
      --    simply never appear as a row here and this key is a no-op for
      --    everyone). A second preference source (e.g. the Build Order 6.3
      --    enquiry-finder, once a ticket->lead link exists) can be OR'd in
      --    here later, e.g. `case when t.id in (v_preferred_tech_id,
      --    v_finder_tech_id) then 0 else 1 end`.
      case when t.id = v_preferred_tech_id then 0 else 1 end asc,
      -- 3. FAIRNESS TIEBREAK: fewer appointments already scheduled that day
      --    (unchanged query -- this was already the second ORDER BY key
      --    before Phase 3; it's simply slotted into its spec-mandated
      --    position #3 now that preference sits above it).
      (
        select count(*) from public.appointments a2
        where a2.technician_id = t.id and a2.scheduled_at::date = coalesce(v_appointment.scheduled_at::date, current_date)
      ) asc,
      -- 4. QUALITY STEER (soft): first, push the customer's own prior <=3*
      --    technician behind other similar-distance candidates (not a hard
      --    exclude -- they can still win if genuinely nearest or if no one
      --    else is close). Then, as a general-purpose secondary signal
      --    (applies to every assignment, not just repeat customers -- this
      --    is intentionally NOT gated on p_skip_rating_logic, since it
      --    reflects the technician's own lifetime track record rather than
      --    this specific customer's history), prefer a higher lifetime
      --    average rating when distances are close. Technicians with no
      --    ratings yet (avg is null) sort last on this key, not first --
      --    they're not penalised elsewhere, just not given an unearned
      --    quality boost over rated peers at the same distance.
      case when t.id = v_deprioritized_tech_id then 1 else 0 end asc,
      (
        select avg(r2.stars) from public.ratings r2
        join public.service_visits sv2 on sv2.id = r2.visit_id
        where sv2.technician_id = t.id
      ) desc nulls last,
      -- 5. DETERMINISTIC FALLBACK (unchanged, still last).
      t.created_at asc
    for update of t skip locked
    limit 1;
  end if;

  if v_tech_id is null then
    select count(*) into v_tech_count from public.technicians where org_id = p_org_id and is_on_duty = true;
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
      format('No free technician is available for ticket %s (%s on-duty).', p_ticket_id, v_tech_count), p_ticket_id);
    return jsonb_build_object('assigned', false, 'reason_key', 'service.assign.noneAvailable');
  end if;

  update public.appointments set technician_id = v_tech_id where id = v_appointment.id;
  update public.service_tickets set status = 'assigned' where id = p_ticket_id;

  -- Logic 3: reset the SLA clock from the moment of assignment, not just
  -- ticket creation. Unchanged since Phase 1.
  select * into v_settings from public.settings where org_id = p_org_id;
  v_sla_hours := case v_ticket.priority
    when 'very_urgent' then v_settings.sla_hours_very_urgent
    when 'urgent' then v_settings.sla_hours_urgent
    else v_settings.sla_hours_normal
  end;
  update public.service_tickets
  set assigned_at = now(), sla_due_at = now() + v_sla_hours * interval '1 hour'
  where id = p_ticket_id;

  insert into public.notifications (org_id, user_id, type, title, body, ref_id)
  select p_org_id, p.id, 'appointment_assigned', 'New job assigned',
         format('Ticket %s assigned to you.', p_ticket_id), v_appointment.id
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  return jsonb_build_object('assigned', true, 'technician_id', v_tech_id, 'appointment_id', v_appointment.id);
end;
$$;

-- Intentionally NOT re-granted -- same reasoning as 20260721100000 /
-- 20260721110000 (unchanged signature, create-or-replace preserves
-- existing grants; this function was never granted to authenticated in the
-- first place).
