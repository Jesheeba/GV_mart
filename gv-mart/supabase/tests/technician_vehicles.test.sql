-- Rolled-back check for 20261107100000_technician_vehicles.sql. Creates its
-- own __TEST_ organisation, master, 7 technicians and a settings row --
-- never reads from or depends on whatever real data already exists. Run
-- through the Management API (database/query); it always ends in a RAISE
-- so nothing persists. Read the RESULTS in the error.
--
-- technician_vehicle_on / technician_own_bike_days are internal-only after
-- the ACL audit (no grant to public, anon OR authenticated -- only their
-- owner and the SECURITY DEFINER functions that call them internally can
-- invoke them). Every call to either below therefore runs on the raw
-- connection (no role switch), exactly how compute_salary/compute_
-- incentives reach them internally; role is switched to 'authenticated'
-- only around the table-level RLS writes/reads this migration's policies
-- actually govern.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_ok boolean;
  v_days int;
  v_row public.technician_vehicles;
begin
  insert into organizations (name) values ('__TEST_technician_vehicles') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'tv-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('tv-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_techp[i];
  end loop;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Overlapping ranges rejected by the database (table write, under RLS as master)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 2.5, '2026-01-01', '2026-01-20');
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
      values (v_org, v_techp[1], 'company', 0, '2026-01-10', '2026-01-25');
    res := res || E'\n' || 'overlapping range: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlapping range: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- Current ownership resolves correctly for a technician with one row
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
  res := res || E'\n' || format('single-row resolve: ownership=%s rate=%s', v_row.ownership, v_row.petrol_rate_per_km);

  delete from technician_vehicles where technician_id = v_techp[1];

  -- Mid-month switch on the 12th of a 31-day month (January): 11 own, 20 company
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'own', 3, '2026-01-01', '2026-01-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techp[1], 'company', 0, '2026-01-12', null);
  select technician_own_bike_days(v_org, v_techp[1], '2026-01-01') into v_days;
  res := res || E'\n' || format('mid-month switch own days (expect 11): %s', v_days);
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-20');
  res := res || E'\n' || format('ownership on the 20th (expect company): %s', v_row.ownership);
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-11');
  res := res || E'\n' || format('ownership on the 11th (expect own): %s', v_row.ownership);

  delete from technician_vehicles where technician_id = v_techp[1];

  -- Technician with no row: resolves to no ownership/rate, nothing crashes
  select * into v_row from technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s, ownership is null = %s', v_row.id is null, v_row.ownership is null);
  select technician_own_bike_days(v_org, v_techp[1], '2026-01-01') into v_days;
  res := res || E'\n' || format('no-row own days (expect 0): %s', v_days);

  -- ACL audit: neither function is granted to authenticated at all -- a
  -- direct RPC call as any real authenticated session, even master, must
  -- fail on permission, not business logic.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform technician_vehicle_on(v_org, v_techp[1], '2026-01-15');
    res := res || E'\n' || 'master calls technician_vehicle_on directly as authenticated: SUCCEEDED (bad, should have no grant)';
  exception when others then
    res := res || E'\n' || 'master calls technician_vehicle_on directly as authenticated: rejected ('||sqlerrm||')';
  end;

  -- A technician cannot read or write this table (table RLS, independent
  -- of the two functions above)
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
    values (v_org, v_techp[1], 'own', 3, '2026-02-01');
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) = 0 into v_ok from technician_vehicles where technician_id = v_techp[1];
  res := res || E'\n' || format('technician SELECT sees nothing: %s', v_ok);
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
      values (v_org, v_techp[1], 'own', 1, '2026-03-01');
    res := res || E'\n' || 'technician INSERT: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician INSERT: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
