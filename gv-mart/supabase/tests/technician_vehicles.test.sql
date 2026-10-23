-- Rolled-back check for 20261024100100_technician_vehicles.sql. Run through
-- the Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_tech uuid; v_techid uuid; v_tech2id uuid;
  v_ok boolean;
  v_days int;
  v_row public.technician_vehicles;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.id into v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Overlapping ranges rejected by the database
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'own', 2.5, '2026-01-01', '2026-01-20');
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
      values (v_org, v_techid, 'company', 0, '2026-01-10', '2026-01-25');
    res := res || E'\n' || 'overlapping range: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlapping range: rejected ('||sqlerrm||')';
  end;

  -- Current ownership resolves correctly for a technician with one row
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-15');
  res := res || E'\n' || format('single-row resolve: ownership=%s rate=%s', v_row.ownership, v_row.petrol_rate_per_km);

  delete from technician_vehicles where technician_id = v_techid;

  -- Mid-month switch on the 12th of a 31-day month (January): 11 own, 20 company
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'own', 3, '2026-01-01', '2026-01-11');
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from, effective_to)
    values (v_org, v_techid, 'company', 0, '2026-01-12', null);
  select technician_own_bike_days(v_org, v_techid, '2026-01-01') into v_days;
  res := res || E'\n' || format('mid-month switch own days (expect 11): %s', v_days);
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-20');
  res := res || E'\n' || format('ownership on the 20th (expect company): %s', v_row.ownership);
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-11');
  res := res || E'\n' || format('ownership on the 11th (expect own): %s', v_row.ownership);

  delete from technician_vehicles where technician_id = v_techid;

  -- Technician with no row: resolves to no ownership/rate, nothing crashes
  select * into v_row from technician_vehicle_on(v_org, v_techid, '2026-01-15');
  res := res || E'\n' || format('no-row resolve: id is null = %s, ownership is null = %s', v_row.id is null, v_row.ownership is null);
  select technician_own_bike_days(v_org, v_techid, '2026-01-01') into v_days;
  res := res || E'\n' || format('no-row own days (expect 0): %s', v_days);

  -- A technician cannot read or write this table
  insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
    values (v_org, v_techid, 'own', 3, '2026-02-01');
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) = 0 into v_ok from technician_vehicles where technician_id = v_techid;
  res := res || E'\n' || format('technician SELECT sees nothing: %s', v_ok);
  begin
    insert into technician_vehicles (org_id, technician_id, ownership, petrol_rate_per_km, effective_from)
      values (v_org, v_techid, 'own', 1, '2026-03-01');
    res := res || E'\n' || 'technician INSERT: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician INSERT: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
