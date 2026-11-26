-- Pin auto-correct (build-docs/features/pin-autocorrect.md).
-- A technician who is at the customer but outside the arrival radius of a wrong (or missing)
-- pin can start the job; their GPS becomes the address pin automatically. No office approval.
-- The corrected pin is NOT locked: the next normal in-radius arrival
-- (record_technician_arrival_address, 20261214100000) confirms and locks it, so two
-- independent visits must agree before a pin becomes final.

-- 1. Max distance a pin may be auto-corrected by. Beyond it the old hard block + office
-- alert (20261212120000) still apply: a pin that far off is bad data, not GPS drift.
alter table public.settings
  add column pin_autocorrect_max_m integer not null default 2000 check (pin_autocorrect_max_m > 0);

-- 2. New event kind.
alter table public.address_location_events drop constraint address_location_events_event_check;
alter table public.address_location_events
  add constraint address_location_events_event_check check (event in ('verified', 'reset', 'corrected'));

-- 3. Correction RPC. Returns the outcome so tests (and a future UI) can tell what happened;
-- the app calls it through the offline outbox and ignores the value.
create function public.record_technician_pin_correction(
  p_org_id uuid,
  p_ticket_id uuid,
  p_lat numeric,
  p_lng numeric,
  p_accuracy_m numeric
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tech_id uuid;
  v_address_id uuid;
  v_customer_id uuid;
  v_addr record;
  v_radius integer;
  v_max integer;
  v_distance numeric;
  v_customer_name text;
  v_tech_name text;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'record_technician_pin_correction: caller is not a technician' using errcode = '42501';
  end if;

  -- Only the technician assigned to this ticket.
  select t.address_id, t.customer_id into v_address_id, v_customer_id
  from service_tickets t
  join appointments a on a.ticket_id = t.id
  where t.id = p_ticket_id and t.org_id = p_org_id and a.technician_id = v_tech_id
  limit 1;
  if v_address_id is null then
    return 'not_assigned';
  end if;

  -- Accuracy is mandatory here (unlike the arrival RPC): this path moves a pin with no
  -- other proof, so a coarse fix must never do it.
  if p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or p_accuracy_m is null or p_accuracy_m < 0 or p_accuracy_m > 75 then
    return 'bad_fix';
  end if;

  select id, lat, lng, location_verified_at into v_addr
  from addresses where id = v_address_id and org_id = p_org_id
  for update;
  if v_addr.id is null then
    return 'not_assigned';
  end if;
  -- A pin verified on site is trusted over a single later reading; only a master reset unlocks it.
  if v_addr.location_verified_at is not null then
    return 'locked';
  end if;

  select geofence_radius_job_m, pin_autocorrect_max_m into v_radius, v_max
  from settings where org_id = p_org_id;
  v_radius := coalesce(v_radius, 250);
  v_max := coalesce(v_max, 2000);

  if v_addr.lat is not null and v_addr.lng is not null then
    v_distance := 2 * 6371000 * asin(sqrt(
      power(sin(radians(p_lat - v_addr.lat) / 2), 2)
      + cos(radians(v_addr.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - v_addr.lng) / 2), 2)
    ));
    if v_distance <= v_radius then
      return 'inside_radius'; -- normal arrival path handles it
    end if;
    if v_distance > v_max then
      return 'too_far';
    end if;
  end if;

  update addresses
  set lat = p_lat, lng = p_lng, pinned_at = now(), location_accuracy_m = p_accuracy_m, updated_at = now()
  where id = v_address_id;

  insert into address_location_events (
    org_id, address_id, event, technician_id, actor_profile_id, ticket_id,
    prev_lat, prev_lng, new_lat, new_lng, distance_m, accuracy_m
  ) values (
    p_org_id, v_address_id, 'corrected', v_tech_id, auth.uid(), p_ticket_id,
    v_addr.lat, v_addr.lng, p_lat, p_lng, round(v_distance, 1), p_accuracy_m
  );

  -- FYI only, no task: nothing for the office to do. Never blocks the correction.
  begin
    select c.name into v_customer_name from customers c where c.id = v_customer_id;
    select p.full_name into v_tech_name from technicians te join profiles p on p.id = te.profile_id where te.id = v_tech_id;
    insert into notifications (org_id, role, type, title, body, ref_id)
    values (
      p_org_id, 'operation_admin', 'pin_autocorrected', 'Customer pin corrected by technician',
      case when v_distance is null
        then format('%s pinned %s''s location on site (it had no pin).', coalesce(v_tech_name, 'A technician'), coalesce(v_customer_name, 'a customer'))
        else format('%s moved %s''s pin %s m to where they actually are. The next visit confirms it.',
          coalesce(v_tech_name, 'A technician'), coalesce(v_customer_name, 'a customer'), round(v_distance))
      end,
      v_customer_id
    );
  exception when others then
    raise warning 'pin_autocorrected notification failed for ticket %: % (sqlstate %)', p_ticket_id, sqlerrm, sqlstate;
  end;

  return 'corrected';
end;
$$;

-- Project auto-grants EXECUTE to anon on new functions; close it explicitly.
revoke all on function public.record_technician_pin_correction(uuid, uuid, numeric, numeric, numeric) from public, anon;
grant execute on function public.record_technician_pin_correction(uuid, uuid, numeric, numeric, numeric) to authenticated;
