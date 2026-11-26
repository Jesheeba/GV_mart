-- Tests for 20261215100000_pin_autocorrect.sql (build-docs/features/pin-autocorrect.md).
-- Run ONLY after the migration is applied. ONE DO block that ALWAYS ends in RAISE, so every
-- write is rolled back whatever happens. Never concatenate this file with the migration.
-- Success = the error text starts with 'ALL PIN-AUTOCORRECT TESTS PASSED'. Anything else = failure.
-- Fixtures: seeded technician@gvmart.test / master@gvmart.test, and the newest ticket assigned to
-- that technician whose address has a pin.
begin;
do $$
declare
  v_tech uuid; v_tech_profile uuid; v_master uuid; v_org uuid;
  v_ticket uuid; v_addr uuid; v_customer uuid;
  v_lat numeric; v_lng numeric;
  v_out text; r record; n int; v_other_tech_profile uuid;
begin
  select id into v_tech_profile from auth.users where email = 'technician@gvmart.test';
  select id into v_master from auth.users where email = 'master@gvmart.test';
  select id into v_tech from technicians where profile_id = v_tech_profile and is_active;

  select t.id, t.org_id, a.id, a.customer_id, a.lat, a.lng
    into v_ticket, v_org, v_addr, v_customer, v_lat, v_lng
  from appointments ap join service_tickets t on t.id = ap.ticket_id join addresses a on a.id = t.address_id
  where ap.technician_id = v_tech and a.lat is not null
  order by t.created_at desc limit 1;
  if v_ticket is null then raise exception 'FIXTURE: no suitable ticket'; end if;

  -- Known settings + clean unlocked state (rolled back anyway).
  update settings set geofence_radius_job_m = 250, pin_autocorrect_max_m = 2000 where org_id = v_org;
  perform set_config('app.address_location_override', 'on', true);
  update addresses set location_verified_at = null, location_verified_by = null where id = v_addr;
  perform set_config('app.address_location_override', 'off', true);

  perform set_config('request.jwt.claims', json_build_object('sub', v_tech_profile, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_tech_profile::text, true);

  -- AC4: inside radius / too far / coarse or missing accuracy -> no change ------------------
  execute 'set local role authenticated';
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.001, v_lng, 20);   -- ~111 m
  if v_out <> 'inside_radius' then raise exception 'AC4 FAIL: inside -> %', v_out; end if;
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.03, v_lng, 20);    -- ~3.3 km
  if v_out <> 'too_far' then raise exception 'AC4 FAIL: too far -> %', v_out; end if;
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.01, v_lng, 120);
  if v_out <> 'bad_fix' then raise exception 'AC4 FAIL: 120m accuracy -> %', v_out; end if;
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.01, v_lng, null);
  if v_out <> 'bad_fix' then raise exception 'AC4 FAIL: null accuracy -> %', v_out; end if;
  execute 'reset role';
  if (select lat from addresses where id = v_addr) <> v_lat then raise exception 'AC4 FAIL: pin moved'; end if;
  if exists (select 1 from address_location_events where address_id = v_addr and event = 'corrected') then
    raise exception 'AC4 FAIL: event logged';
  end if;

  -- AC1: ~1.1 km off, accuracy 20 m -> pin moves, NOT locked, one event, one FYI notification --
  select count(*) into n from notifications where org_id = v_org and type = 'pin_autocorrected';
  execute 'set local role authenticated';
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.01, v_lng, 20);
  execute 'reset role';
  if v_out <> 'corrected' then raise exception 'AC1 FAIL: -> %', v_out; end if;
  select * into r from addresses where id = v_addr;
  if r.lat <> v_lat + 0.01 or r.lng <> v_lng or r.location_verified_at is not null or r.location_accuracy_m <> 20 then
    raise exception 'AC1 FAIL: address (%)', row_to_json(r);
  end if;
  select * into r from address_location_events where address_id = v_addr and event = 'corrected';
  if r.prev_lat <> v_lat or r.new_lat <> v_lat + 0.01 or r.distance_m not between 1100 and 1125
     or r.technician_id <> v_tech or r.ticket_id <> v_ticket then
    raise exception 'AC1 FAIL: event (%)', row_to_json(r);
  end if;
  if (select count(*) from notifications where org_id = v_org and type = 'pin_autocorrected' and ref_id = v_customer) <> n + 1 then
    raise exception 'AC1 FAIL: notification count';
  end if;
  if exists (select 1 from tasks where ref_id = v_customer and ref_type = 'pin_autocorrected') then
    raise exception 'AC1 FAIL: a task was created (must be FYI only)';
  end if;

  -- AC2: next normal in-radius arrival at the corrected pin locks it (two visits agree) ------
  execute 'set local role authenticated';
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0103, v_lng, 15);   -- ~33 m from new pin
  execute 'reset role';
  if (select location_verified_at from addresses where id = v_addr) is null then raise exception 'AC2 FAIL: not locked'; end if;

  -- AC3: a locked pin is never auto-corrected -----------------------------------------------
  execute 'set local role authenticated';
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.02, v_lng, 10);
  execute 'reset role';
  if v_out <> 'locked' then raise exception 'AC3 FAIL: -> %', v_out; end if;
  if (select lat from addresses where id = v_addr) <> v_lat + 0.0103 then raise exception 'AC3 FAIL: locked pin moved'; end if;

  -- AC5: no pin -> technician's location becomes the pin, distance null -------------------------
  perform set_config('app.address_location_override', 'on', true);
  update addresses set lat = null, lng = null, location_verified_at = null, location_verified_by = null where id = v_addr;
  perform set_config('app.address_location_override', 'off', true);
  execute 'set local role authenticated';
  v_out := record_technician_pin_correction(v_org, v_ticket, v_lat, v_lng, 30);
  execute 'reset role';
  if v_out <> 'corrected' then raise exception 'AC5 FAIL: -> %', v_out; end if;
  select * into r from addresses where id = v_addr;
  if r.lat <> v_lat or r.lng <> v_lng or r.location_verified_at is not null then raise exception 'AC5 FAIL: (%)', row_to_json(r); end if;
  if not exists (select 1 from address_location_events where address_id = v_addr and event = 'corrected' and prev_lat is null and distance_m is null) then
    raise exception 'AC5 FAIL: event';
  end if;

  -- AC6: another technician -> not_assigned; a non-technician -> rejected ---------------------
  select profile_id into v_other_tech_profile from technicians where is_active and id <> v_tech and org_id = v_org limit 1;
  if v_other_tech_profile is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_tech_profile, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_other_tech_profile::text, true);
    execute 'set local role authenticated';
    v_out := record_technician_pin_correction(v_org, v_ticket, v_lat + 0.01, v_lng, 10);
    execute 'reset role';
    if v_out <> 'not_assigned' then raise exception 'AC6 FAIL: other technician -> %', v_out; end if;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_master::text, true);
  begin
    execute 'set local role authenticated';
    perform record_technician_pin_correction(v_org, v_ticket, v_lat + 0.01, v_lng, 10);
    raise exception 'AC6 FAIL: non-technician accepted';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  -- AC7: anon cannot execute ------------------------------------------------------------------
  if has_function_privilege('anon', 'public.record_technician_pin_correction(uuid, uuid, numeric, numeric, numeric)', 'execute') then
    raise exception 'AC7 FAIL: anon has EXECUTE';
  end if;

  raise exception 'ALL PIN-AUTOCORRECT TESTS PASSED (everything rolled back)';
end;
$$;
rollback;
