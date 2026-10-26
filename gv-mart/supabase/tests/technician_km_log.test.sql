-- Rolled-back check for 20261107100100_technician_km_log.sql. Run through
-- the Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid; v_tech uuid; v_techid uuid; v_tech2id uuid; v_tech2 uuid;
  v_sum numeric; v_id uuid; v_n int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.profile_id, t.id into v_tech2, v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Entries accumulate; the monthly sum is the sum of entries
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-05', 10);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-20', 15.5);
  select technician_km_log_sum(v_org, v_techid, '2026-01-01') into v_sum;
  res := res || E'\n' || format('monthly sum (expect 25.5): %s', v_sum);

  -- An entry dated outside the filtered range does not appear and does not count
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-02-01', 99);
  select technician_km_log_sum(v_org, v_techid, '2026-01-01') into v_sum;
  res := res || E'\n' || format('January sum unaffected by February entry (expect 25.5): %s', v_sum);

  -- The monthly sum for a technician with no entries is zero, not null
  select technician_km_log_sum(v_org, v_tech2id, '2026-01-01') into v_sum;
  res := res || E'\n' || format('no-entries sum (expect 0, not null): %s, is null = %s', v_sum, v_sum is null);

  -- There is no code path that updates or deletes an entry — default-deny:
  -- no update/delete policy exists at all, even for master. Checked as
  -- 'authenticated'/master, not the superuser connection running this
  -- block, since RLS does not apply to a superuser/BYPASSRLS role at all
  -- regardless of policies.
  select id into v_id from technician_km_log where technician_id = v_techid order by entry_date limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    update technician_km_log set km = 1 where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('UPDATE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'UPDATE km_log as master: rejected ('||sqlerrm||')';
  end;
  begin
    delete from technician_km_log where id = v_id;
    get diagnostics v_n = row_count;
    res := res || E'\n' || format('DELETE km_log as master: %s row(s) (bad if > 0)', v_n);
  exception when others then
    res := res || E'\n' || 'DELETE km_log as master: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- A technician reads only their own entries
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_km_log where technician_id = v_techid;
  res := res || E'\n' || format('technician2 sees technician1 rows (expect 0): %s', v_n);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_tech2id, '2026-01-07', 5);
  select count(*) into v_n from technician_km_log where technician_id = v_tech2id;
  res := res || E'\n' || format('technician2 sees own rows after own insert (expect 1): %s', v_n);
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techid, '2026-01-08', 5);
    res := res || E'\n' || 'technician2 INSERT for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 INSERT for technician1: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
