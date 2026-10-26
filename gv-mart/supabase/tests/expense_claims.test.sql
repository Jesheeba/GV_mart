-- Rolled-back check for 20261107100200_expense_claims.sql. Run through the
-- Management API (database/query); it always ends in a RAISE so nothing
-- persists. Read the RESULTS in the error.
--
-- Not exercised here (needs the real Storage HTTP API, not plain SQL): bucket
-- file_size_limit / allowed_mime_types enforcement on an actual upload. The
-- storage.objects RLS policies themselves are checked below.
do $t$
declare
  res text := '';
  v_org uuid; v_tech uuid; v_techid uuid; v_tech2 uuid; v_tech2id uuid; v_master uuid;
  v_claim public.expense_claims; v_n int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  select id into v_master from profiles where role='master' limit 1;
  select t.profile_id, t.id into v_tech, v_techid from technicians t limit 1;
  select t.profile_id, t.id into v_tech2, v_tech2id from technicians t where t.id <> v_techid limit 1;

  -- Technician submits a claim via the RPC (identity resolved server-side)
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_claim from submit_expense_claim(v_org, 'maintenance', 500, v_techid::text || '/bill1.jpg', '2026-01-01');
  execute 'reset role';
  res := res || E'\n' || format('submitted claim: verified_amount is null = %s', v_claim.verified_amount is null);

  -- A claim with verified_amount null is invisible to salary/the report
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('unverified claim total (expect 0): %s', v_n);

  -- verified_amount differing from submitted_amount with a null reason is
  -- rejected by the database (CHECK constraint), not just the form
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform verify_expense_claim(v_claim.id, 300, null);
    res := res || E'\n' || 'verify with differing amount + null reason: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'verify with differing amount + null reason: rejected ('||sqlerrm||')';
  end;

  -- Same amount, no reason needed: succeeds
  select * into v_claim from verify_expense_claim(v_claim.id, 500, null);
  res := res || E'\n' || format('verify same amount, no reason: verified_amount=%s', v_claim.verified_amount);
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('verified claim total (expect 500): %s', v_n);

  -- A verified amount of zero behaves as a rejection: nothing paid, row and
  -- photo path survive, reason is readable
  select * into v_claim from verify_expense_claim(v_claim.id, 0, 'bill illegible, rejected');
  res := res || E'\n' || format('verify at zero: verified_amount=%s reason=%s photo_survives=%s', v_claim.verified_amount, v_claim.reason, v_claim.bill_photo_path is not null);
  select technician_expense_claims_total(v_org, v_techid, '2026-01-01', 'maintenance') into v_n;
  res := res || E'\n' || format('total after zero-verify (expect 0): %s', v_n);
  select count(*) into v_n from expense_claims where id = v_claim.id;
  res := res || E'\n' || format('row still exists after zero-verify (expect 1): %s', v_n);
  execute 'reset role';

  -- A technician cannot read another technician's claim
  perform set_config('request.jwt.claims', json_build_object('sub', v_tech2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from expense_claims where technician_id = v_techid;
  res := res || E'\n' || format('technician2 reading technician1 claims (expect 0): %s', v_n);
  begin
    perform verify_expense_claim(v_claim.id, 1, 'trying to verify as a technician');
    res := res || E'\n' || 'technician verify_expense_claim: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician verify_expense_claim: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- The photograph bucket is not publicly reachable without authentication
  execute 'set local role anon';
  select count(*) into v_n from storage.objects where bucket_id = 'expense-claim-photos';
  res := res || E'\n' || format('anon SELECT on expense-claim-photos bucket rows (expect 0): %s', v_n);
  execute 'reset role';

  raise exception E'RESULTS%', res;
end $t$;
