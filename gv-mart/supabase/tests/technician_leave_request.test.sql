-- Rolled-back check for 20261106100000_technician_leave_request.sql. Uses its own throwaway
-- organisation so this test's requests/availability/attendance rows never interact with another
-- org's data. Run through the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
--
-- AMC leave trigger (zz_amc_release_on_leave): migration 20261025100000 is NOT applied in this
-- branch's ancestry (it lives on the unmerged feat/amc-release-path only — see the migration's
-- header note). There is nothing to test here; this is stated, not silently skipped.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1id uuid; v_t2 uuid; v_t2id uuid; v_ctrl uuid; v_ctrlid uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_req uuid; v_req2 uuid; v_reject uuid; v_cancel uuid; v_revoke uuid;
  v_row public.technician_leave_requests;
  v_n int; v_ok boolean;
  v_real_org uuid; v_fp_before int; v_fp_after int; v_setting_before int; v_setting_after int;
begin
  -- ── real-org fingerprint, taken before anything else ──────────────────────────────────────
  select id into v_real_org from organizations where name not like '\_\_TEST\_%' limit 1;
  select count(*) into v_fp_before from technician_availability where org_id = v_real_org;
  select leave_notice_days into v_setting_before from settings where org_id = v_real_org;

  -- ── throwaway org + actors ────────────────────────────────────────────────────────────────
  insert into organizations (name) values ('__TEST_technician_leave_request') returning id into v_org;
  insert into settings (org_id, leave_notice_days) values (v_org, 3);

  v_master := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_master, 'authenticated', 'authenticated', 'leave-master@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  v_t1 := gen_random_uuid(); v_t2 := gen_random_uuid(); v_ctrl := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 'leave-t1@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 'leave-t2@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_ctrl, 'authenticated', 'authenticated', 'leave-ctrl@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_ctrl, v_org, '__TEST_ ctrl', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1id;
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2id;
  insert into technicians (org_id, profile_id) values (v_org, v_ctrl) returning id into v_ctrlid;

  -- ══ KPI exclusion (reward_candidates' "expected working days"), fixed calendar dates so this
  --    case does not depend on when the rehearsal actually runs ══════════════════════════════
  -- org operates 2026-03-08/09/10 (control technician present all three days)
  insert into attendance (org_id, technician_id, date, check_in_at, is_late) values
    (v_org, v_ctrlid, '2026-03-08', '2026-03-08 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-10', '2026-03-10 09:00+05:30', false),
    -- t1 present 08/09, misses 10th (will be protected leave)
    (v_org, v_t1id, '2026-03-08', '2026-03-08 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-09', '2026-03-09 09:00+05:30', false),
    -- t2 present 08/09, misses 10th (will be LATE leave, not protected)
    (v_org, v_t2id, '2026-03-08', '2026-03-08 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-09', '2026-03-09 09:00+05:30', false);

  -- t1: requested 2026-03-01 for 2026-03-10 (9 days' notice, >= leave_notice_days=3 -> protected)
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t1id, '2026-03-10', '2026-03-10', v_t1, '2026-03-01 10:00+05:30')
    returning id into v_req;
  -- t2: requested 2026-03-09 for 2026-03-10 (1 day's notice, < 3 -> NOT protected = "late")
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t2id, '2026-03-10', '2026-03-10', v_t2, '2026-03-09 10:00+05:30')
    returning id into v_req2;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select * into v_row from decide_technician_leave(v_req, 'approved');
  res := res || E'\n' || format('t1 (in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req2, 'approved');
  res := res || E'\n' || format('t2 (late) approved, protected (expect false): %s', v_row.protected);

  select count(*) = 1 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t1id;
  res := res || E'\n' || format('KPI: protected t1 counted as fully attended (expect true): %s', v_ok);
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t2id;
  res := res || E'\n' || format('KPI: late t2 NOT counted as fully attended (expect true): %s', v_ok);

  select count(*) into v_n from technician_availability where leave_request_id = v_req and status = 'leave' and protected;
  res := res || E'\n' || format('t1 approved leave materialised as protected technician_availability row (expect 1): %s', v_n);

  execute 'reset role';

  -- ══ status transitions: reject / cancel / revoke (today-relative, independent technician v_t1) ══
  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select (request_technician_leave(v_today + 15, v_today + 15, 'reject me')).id into v_reject;
  select (request_technician_leave(v_today + 16, v_today + 16, 'cancel me')).id into v_cancel;
  select (request_technician_leave(v_today + 17, v_today + 17, 'revoke me')).id into v_revoke;
  res := res || E'\n' || 'three pending requests created for t1 (today+15/16/17)';

  -- overlap with an existing pending request is refused by the database
  begin
    perform request_technician_leave(v_today + 17, v_today + 17, 'dup');
    res := res || E'\n' || 'overlap: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'overlap: rejected ('||sqlerrm||')';
  end;

  -- date validation refused by the database
  begin
    perform request_technician_leave(v_today + 20, v_today + 19, null);
    res := res || E'\n' || 'end before start: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'end before start: rejected ('||sqlerrm||')';
  end;
  begin
    perform request_technician_leave(v_today, v_today, null);
    res := res || E'\n' || 'start not in the future: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'start not in the future: rejected ('||sqlerrm||')';
  end;
  begin
    perform request_technician_leave(v_today + 30, v_today + 65, null);
    res := res || E'\n' || 'request over 30 days: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'request over 30 days: rejected ('||sqlerrm||')';
  end;

  -- a technician cannot approve their own request, or anyone else's
  begin
    perform decide_technician_leave(v_reject, 'approved', null);
    res := res || E'\n' || 'technician approves own request: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician approves own request: rejected ('||sqlerrm||')';
  end;

  execute 'reset role';

  -- master rejects / t1 cancels / master approves then revokes
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from decide_technician_leave(v_reject, 'rejected', 'not enough cover that week');
  res := res || E'\n' || format('reject: status (expect rejected): %s', v_row.status);
  select * into v_row from decide_technician_leave(v_revoke, 'approved');
  res := res || E'\n' || format('pre-revoke approve: status (expect approved): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('pre-revoke: availability row exists (expect 1): %s', v_n);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from cancel_technician_leave(v_cancel);
  res := res || E'\n' || format('t1 cancels own pending request: status (expect cancelled): %s', v_row.status);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from decide_technician_leave(v_revoke, 'revoked', 'cover arranged, leave withdrawn');
  res := res || E'\n' || format('revoke: status (expect revoked): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('post-revoke: availability row removed (expect 0): %s', v_n);
  execute 'reset role';

  -- ══ RLS: one technician cannot see another technician's requests ═══════════════════════════
  perform set_config('request.jwt.claims', json_build_object('sub', v_t2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from technician_leave_requests where technician_id = v_t1id;
  res := res || E'\n' || format('t2 sees t1''s requests (expect 0): %s', v_n);
  select count(*) > 0 into v_ok from technician_leave_requests where technician_id = v_t2id;
  res := res || E'\n' || format('t2 sees own requests (expect true): %s', v_ok);
  -- t2 also cannot approve t1's untouched request, or anyone's
  begin
    perform decide_technician_leave(v_req, 'approved', null);
    res := res || E'\n' || 'technician approves someone else''s request: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'technician approves someone else''s request: rejected ('||sqlerrm||')';
  end;
  execute 'reset role';

  -- ══ real-org data unchanged ═════════════════════════════════════════════════════════════
  select count(*) into v_fp_after from technician_availability where org_id = v_real_org;
  select leave_notice_days into v_setting_after from settings where org_id = v_real_org;
  res := res || E'\n' || format('real org technician_availability count unchanged (expect true): %s', v_fp_before = v_fp_after);
  res := res || E'\n' || format('real org leave_notice_days unchanged (expect true): %s', v_setting_before = v_setting_after);

  raise exception E'RESULTS%', res;
end $t$;
