-- Tests for 20261214100000_arrival_location_lock.sql (build-docs/features/arrival-location-lock.md).
-- Runs as ONE DO block that ALWAYS ends in RAISE, so every write is rolled back whatever happens.
-- Success = the error text starts with 'ALL ARRIVAL-LOCK TESTS PASSED'. Any other error = a failure.
-- Fixtures: seeded technician@gvmart.test / master@gvmart.test / operation_admin@gvmart.test,
-- and the newest ticket assigned to that technician whose customer has 2 addresses.
begin;
do $$
declare
  v_tech uuid; v_tech_profile uuid; v_master uuid; v_opadmin uuid; v_org uuid;
  v_ticket uuid; v_addr uuid; v_customer uuid; v_second uuid;
  v_lat numeric; v_lng numeric; v_radius int;
  r record; n int; v_other_tech_profile uuid; v_new_addr uuid;

begin
  select id into v_tech_profile from auth.users where email = 'technician@gvmart.test';
  select id into v_master from auth.users where email = 'master@gvmart.test';
  select id into v_opadmin from auth.users where email = 'operation_admin@gvmart.test';
  select id into v_tech from technicians where profile_id = v_tech_profile and is_active;

  select t.id, t.org_id, a.id, a.customer_id, a.lat, a.lng
    into v_ticket, v_org, v_addr, v_customer, v_lat, v_lng
  from appointments ap join service_tickets t on t.id = ap.ticket_id join addresses a on a.id = t.address_id
  where ap.technician_id = v_tech and a.lat is not null
    and (select count(*) from addresses a2 where a2.customer_id = a.customer_id) >= 2
  order by t.created_at desc limit 1;
  if v_ticket is null then raise exception 'FIXTURE: no suitable ticket'; end if;
  select coalesce(geofence_radius_job_m, 250) into v_radius from settings where org_id = v_org;
  -- Start from a clean, unlocked state (rolled back anyway).
  perform set_config('app.address_location_override', 'on', true);
  update addresses set location_verified_at = null, location_verified_by = null where customer_id = v_customer;
  perform set_config('app.address_location_override', 'off', true);

  -- AC1: first in-radius arrival (~55m, accuracy 20m) locks + logs one event --------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech_profile, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_tech_profile::text, true);
  execute 'set local role authenticated';
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0005, v_lng, 20);
  execute 'reset role';
  select * into r from addresses where id = v_addr;
  if r.location_verified_at is null or r.location_verified_by <> v_tech or r.lat <> v_lat + 0.0005 or r.location_accuracy_m <> 20 then
    raise exception 'AC1 FAIL: not locked/updated (%)', row_to_json(r);
  end if;
  select count(*) into n from address_location_events where address_id = v_addr and event = 'verified';
  if n <> 1 then raise exception 'AC1 FAIL: % verified events', n; end if;
  select * into r from address_location_events where address_id = v_addr;
  if r.prev_lat <> v_lat or r.new_lat <> v_lat + 0.0005 or r.distance_m not between 50 and 60 or r.ticket_id <> v_ticket then
    raise exception 'AC1 FAIL: event wrong (%)', row_to_json(r);
  end if;

  -- AC2: second arrival changes nothing --------------------------------------------------
  execute 'set local role authenticated';
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0009, v_lng, 10);
  execute 'reset role';
  if (select lat from addresses where id = v_addr) <> v_lat + 0.0005 then raise exception 'AC2 FAIL: locked pin moved'; end if;
  if (select count(*) from address_location_events where address_id = v_addr) <> 1 then raise exception 'AC2 FAIL: extra event'; end if;

  -- AC5: direct writes to a locked pin / verified_* are rejected (master via PostgREST role, and postgres) --
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_master::text, true);
  begin
    execute 'set local role authenticated';
    update addresses set lat = lat + 0.01 where id = v_addr;
    raise exception 'AC5 FAIL: master moved a locked pin';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    update addresses set location_verified_at = null where id = v_addr;
    raise exception 'AC5 FAIL: master cleared verified_at directly';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  begin
    update addresses set lng = lng + 0.01 where id = v_addr; -- as postgres, no override flag
    raise exception 'AC5 FAIL: postgres moved a locked pin without the override';
  exception when insufficient_privilege then null;
  end;

  -- AC6: text edit on a locked address saves and the pin stays ----------------------------
  execute 'set local role authenticated';
  update addresses set landmark = 'arrival-lock test landmark' where id = v_addr;
  execute 'reset role';
  select * into r from addresses where id = v_addr;
  if r.landmark is distinct from 'arrival-lock test landmark' or r.lat <> v_lat + 0.0005 or r.location_verified_at is null then
    raise exception 'AC6 FAIL: text edit (%)', row_to_json(r);
  end if;

  -- AC7: reset is master-only, needs a reason, keeps the pin, logs 'reset' -----------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_opadmin, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_opadmin::text, true);
  begin
    execute 'set local role authenticated';
    perform reset_address_location_verification(v_addr, 'customer moved');
    raise exception 'AC7 FAIL: operation_admin could reset';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_master::text, true);
  begin
    execute 'set local role authenticated';
    perform reset_address_location_verification(v_addr, '  ');
    raise exception 'AC7 FAIL: reset without reason allowed';
  exception when invalid_parameter_value then null;
  end;
  execute 'reset role';
  execute 'set local role authenticated';
  perform reset_address_location_verification(v_addr, 'customer moved house');
  execute 'reset role';
  select * into r from addresses where id = v_addr;
  if r.location_verified_at is not null or r.location_verified_by is not null or r.lat <> v_lat + 0.0005 then
    raise exception 'AC7 FAIL: reset state (%)', row_to_json(r);
  end if;
  if (select count(*) from address_location_events where address_id = v_addr and event = 'reset' and reason = 'customer moved house' and actor_profile_id = v_master) <> 1 then
    raise exception 'AC7 FAIL: reset event missing';
  end if;

  -- AC4: out-of-radius (~2.2km) or poor accuracy (120m) does not lock ------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech_profile, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_tech_profile::text, true);
  execute 'set local role authenticated';
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.02, v_lng, 10);
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0006, v_lng, 120);
  execute 'reset role';
  select * into r from addresses where id = v_addr;
  if r.location_verified_at is not null or r.lat <> v_lat + 0.0005 then raise exception 'AC4 FAIL: locked/moved (%)', row_to_json(r); end if;

  -- AC8: a technician not assigned to the ticket changes nothing; a non-technician is rejected --
  select profile_id into v_other_tech_profile from technicians where is_active and id <> v_tech and org_id = v_org limit 1;
  if v_other_tech_profile is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_other_tech_profile, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_other_tech_profile::text, true);
    execute 'set local role authenticated';
    perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0005, v_lng, 10);
    execute 'reset role';
    if (select location_verified_at from addresses where id = v_addr) is not null then raise exception 'AC8 FAIL: other technician locked it'; end if;
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_master::text, true);
  begin
    execute 'set local role authenticated';
    perform record_technician_arrival_address(v_org, v_ticket, v_lat, v_lng, 10);
    raise exception 'AC8 FAIL: non-technician accepted';
  exception when raise_exception then
    if sqlerrm not like '%caller is not a technician%' then raise; end if;
  end;
  execute 'reset role';

  -- AC3: arrival at a SECONDARY address locks it and changes no is_primary flag, no new rows --
  select id into v_second from addresses where customer_id = v_customer and id <> v_addr limit 1;
  update addresses set lat = v_lat + 0.01, lng = v_lng, is_primary = false where id = v_second;
  update addresses set is_primary = true where id = v_addr;
  update service_tickets set address_id = v_second where id = v_ticket;
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech_profile, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_tech_profile::text, true);
  execute 'set local role authenticated';
  perform record_technician_arrival_address(v_org, v_ticket, v_lat + 0.0103, v_lng, 15);
  execute 'reset role';
  if (select location_verified_at from addresses where id = v_second) is null then raise exception 'AC3 FAIL: secondary not locked'; end if;
  if (select is_primary from addresses where id = v_second) or not (select is_primary from addresses where id = v_addr) then
    raise exception 'AC3 FAIL: primary flag changed';
  end if;
  if (select count(*) from addresses where customer_id = v_customer) <> 2 then raise exception 'AC3 FAIL: address rows added'; end if;

  -- Guard: a new address can never be inserted pre-verified ---------------------------------
  insert into addresses (org_id, customer_id, full_address, is_primary, location_verified_at, location_verified_by)
  values (v_org, v_customer, 'arrival-lock insert test', false, now(), v_tech)
  returning id into v_new_addr;
  if (select location_verified_at from addresses where id = v_new_addr) is not null then
    raise exception 'GUARD FAIL: insert kept verified_at';
  end if;

  raise exception 'ALL ARRIVAL-LOCK TESTS PASSED (everything rolled back)';
end;
$$;
rollback;
