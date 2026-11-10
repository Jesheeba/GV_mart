-- Rolled-back check for 20261107100100_technician_km_log.sql. Creates its
-- own __TEST_ organisation, master, 7 technicians and a settings row --
-- never reads from or depends on whatever real data already exists. Run
-- through the Management API (database/query); it always ends in a RAISE
-- so nothing persists. Read the RESULTS in the error.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_sum numeric; v_id uuid; v_n int;
  v_org2 uuid; v_master2 uuid; v_tech2org uuid; v_tech2orgp uuid;
  v_new_id uuid;
begin
  insert into organizations (name) values ('__TEST_technician_km_log') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'kl-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('kl-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_new_id;
    v_techp[i] := v_new_id;
  end loop;

  -- A second, unrelated organisation and its own technician -- used only
  -- for the two cross-org insert checks below.
  insert into organizations (name) values ('__TEST_technician_km_log_other') returning id into v_org2;
  insert into settings (org_id) values (v_org2);
  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'kl-master2@test.invalid')
    returning id into v_master2;
  insert into profiles (id, org_id, full_name, role) values (v_master2, v_org2, '__TEST_ master2', 'master');
  v_tech2org := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_tech2org, 'authenticated', 'authenticated', 'kl-tech-org2@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_tech2org, v_org2, '__TEST_ tech-org2', 'technician');
  insert into technicians (org_id, profile_id) values (v_org2, v_tech2org) returning id into v_tech2orgp;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  -- Entries accumulate; the monthly sum is the sum of entries
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-05', 10);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-20', 15.5);
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('monthly sum (expect 25.5): %s', v_sum);

  -- An entry dated outside the filtered range does not appear and does not count
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-02-01', 99);
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('January sum unaffected by February entry (expect 25.5): %s', v_sum);

  -- The monthly sum for a technician with no entries is zero, not null
  select technician_km_log_sum(v_org, v_techp[2], '2026-01-01') into v_sum;
  res := res || E'\n' || format('no-entries sum (expect 0, not null): %s, is null = %s', v_sum, v_sum is null);

  -- Master (is_ops_staff) can read any technician's sum in-org
  select technician_km_log_sum(v_org, v_techp[1], '2026-01-01') into v_sum;
  res := res || E'\n' || format('master reads technician1 sum (expect 25.5): %s', v_sum);

  -- There is no code path that updates or deletes an entry — default-deny:
  -- no update/delete policy exists at all, even for master. Checked as
  -- 'authenticated'/master, not the superuser connection running this
  -- block, since RLS does not apply to a superuser/BYPASSRLS role at all
  -- regardless of policies.
  select id into v_id from technician_km_log where technician_id = v_techp[1] order by entry_date limit 1;
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

  -- A technician reads only their own entries, and technician_km_log_sum
  -- refuses for another technician's id (ACL audit fix: this function used
  -- to have no caller/org check at all).
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[2], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_km_log where technician_id = v_techp[1];
  res := res || E'\n' || format('technician2 sees technician1 rows (expect 0): %s', v_n);
  insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[2], '2026-01-07', 5);
  select count(*) into v_n from technician_km_log where technician_id = v_techp[2];
  res := res || E'\n' || format('technician2 sees own rows after own insert (expect 1): %s', v_n);
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_techp[1], '2026-01-08', 5);
    res := res || E'\n' || 'technician2 INSERT for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 INSERT for technician1: rejected ('||sqlerrm||')';
  end;
  select technician_km_log_sum(v_org, v_techp[2], '2026-01-01') into v_sum;
  res := res || E'\n' || format('technician2 reads own sum via RPC (expect 5): %s', v_sum);
  begin
    perform technician_km_log_sum(v_org, v_techp[1], '2026-01-01');
    res := res || E'\n' || 'technician2 calls technician_km_log_sum for technician1: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician2 calls technician_km_log_sum for technician1: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- CROSS-ORG CHECK 1 (insert_own, this review's fix): technician 3 (a
  -- real member of v_org) tries to insert a km_log row tagged with
  -- v_org2 -- their own org, not the row's. Before this fix, insert_own
  -- checked only technician_id, with no org_id condition at all, so this
  -- would have succeeded.
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[3], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org2, v_techp[3], '2026-01-09', 5);
    res := res || E'\n' || 'CROSS-ORG 1: technician3 inserts tagged with the OTHER org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG 1: technician3 inserts tagged with the OTHER org: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- CROSS-ORG CHECK 2 (insert_staff, this review's fix): master (ops
  -- staff of v_org) tries to insert a row with org_id = v_org (their own
  -- org, satisfying the old check) but technician_id pointing at a
  -- technician who actually belongs to v_org2. Before this fix,
  -- insert_staff never verified that relationship, so this would have
  -- succeeded and logged km against a technician in a different
  -- organisation entirely.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into technician_km_log (org_id, technician_id, entry_date, km) values (v_org, v_tech2orgp, '2026-01-09', 5);
    res := res || E'\n' || 'CROSS-ORG 2: master inserts for a technician who belongs to a different org: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'CROSS-ORG 2: master inserts for a technician who belongs to a different org: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
