-- Rolled-back check for 20261107100200_expense_claims.sql. Creates its own
-- __TEST_ organisation, master, 7 technicians and a settings row -- never
-- reads from or depends on whatever real data already exists. Run through
-- the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
--
-- Not exercised here (needs the real Storage HTTP API, not plain SQL): bucket
-- file_size_limit / allowed_mime_types enforcement on an actual upload. The
-- storage.objects RLS policies themselves are checked below.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_tech uuid[] := '{}'; v_techp uuid[] := '{}';
  i int;
  v_claim public.expense_claims; v_n int;
  v_salary salaries;
begin
  insert into organizations (name) values ('__TEST_expense_claims') returning id into v_org;
  insert into settings (org_id) values (v_org);

  insert into auth.users (id, aud, role, email) values (gen_random_uuid(), 'authenticated', 'authenticated', 'ec-master@test.invalid')
    returning id into v_master;
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  for i in 1..7 loop
    v_tech := array_append(v_tech, gen_random_uuid());
    insert into auth.users (id, aud, role, email) values (v_tech[i], 'authenticated', 'authenticated', format('ec-tech%s@test.invalid', i));
    insert into profiles (id, org_id, full_name, role) values (v_tech[i], v_org, format('__TEST_ tech%s', i), 'technician');
    v_techp := array_append(v_techp, null);
    insert into technicians (org_id, profile_id) values (v_org, v_tech[i]) returning id into v_techp[i];
  end loop;

  -- Technician submits a claim via the RPC (identity resolved server-side)
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[1], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 500, v_techp[1]::text || '/bill1.jpg', '2026-01-01');
  execute 'reset role';
  res := res || E'\n' || format('submitted claim: verified_amount is null = %s', v_claim.verified_amount is null);

  -- A claim with verified_amount null is invisible to salary/the report.
  -- technician_expense_claims_total itself is internal-only now (ACL
  -- audit: no caller/org check, not granted to any role at all except its
  -- owner) -- so this is checked the way the real app actually reaches it,
  -- through compute_salary, which is granted and calls it internally.
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('unverified claim excluded from compute_salary.maintenance_amount (expect 0): %s', v_salary.maintenance_amount);

  -- verified_amount differing from submitted_amount with a null reason is
  -- rejected by the database (CHECK constraint), not just the form
  begin
    perform verify_expense_claim(v_claim.id, 300, null);
    res := res || E'\n' || 'verify with differing amount + null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'verify with differing amount + null reason: rejected ('||sqlerrm||')';
  end;

  -- Same amount, no reason needed: succeeds
  select * into v_claim from verify_expense_claim(v_claim.id, 500, null);
  res := res || E'\n' || format('verify same amount, no reason: verified_amount=%s', v_claim.verified_amount);
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('verified claim total via compute_salary (expect 500): %s', v_salary.maintenance_amount);

  -- A verified amount of zero behaves as a rejection: nothing paid, row and
  -- photo path survive, reason is readable
  select * into v_claim from verify_expense_claim(v_claim.id, 0, 'bill illegible, rejected');
  res := res || E'\n' || format('verify at zero: verified_amount=%s reason=%s photo_survives=%s', v_claim.verified_amount, v_claim.reason, v_claim.bill_photo_path is not null);
  select * into v_salary from compute_salary(v_org, v_techp[1], '2026-01-01');
  res := res || E'\n' || format('total after zero-verify via compute_salary (expect 0): %s', v_salary.maintenance_amount);
  select count(*) into v_n from expense_claims where id = v_claim.id;
  res := res || E'\n' || format('row still exists after zero-verify (expect 1): %s', v_n);
  execute 'reset role';

  -- A technician cannot read another technician's claim
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech[2], 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from expense_claims where technician_id = v_techp[1];
  res := res || E'\n' || format('technician2 reading technician1 claims (expect 0): %s', v_n);
  begin
    perform verify_expense_claim(v_claim.id, 1, 'trying to verify as a technician');
    res := res || E'\n' || 'technician verify_expense_claim: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician verify_expense_claim: rejected ('||sqlerrm||')';
  end;
  begin
    perform technician_expense_claims_total(v_org, v_techp[1], '2026-01-01', 'maintenance');
    res := res || E'\n' || 'technician2 calls technician_expense_claims_total directly: SUCCEEDED (expect FAIL, not granted at all -- ACL audit)';
  exception when others then
    res := res || E'\n' || 'technician2 calls technician_expense_claims_total directly: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- The photograph bucket is not publicly reachable without authentication
  execute 'set local role anon';
  select count(*) into v_n from storage.objects where bucket_id = 'expense-claim-photos';
  res := res || E'\n' || format('anon SELECT on expense-claim-photos bucket rows (expect 0): %s', v_n);
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
