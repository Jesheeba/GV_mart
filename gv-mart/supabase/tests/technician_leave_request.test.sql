-- Rolled-back check for 20261106100000_technician_leave_request.sql. Uses its own throwaway
-- organisation so this test's requests/availability/attendance rows never interact with another
-- org's data. Run through the Management API (database/query); it always ends in a RAISE so
-- nothing persists. Read the RESULTS in the error.
--
-- AMC leave trigger (zz_amc_release_on_leave): migration 20261025100000 is NOT applied in this
-- branch's ancestry (it lives on the unmerged feat/amc-release-path only — see the migration's
-- header note). There is nothing to test here; this is stated, not silently skipped.
--
-- TEST NOTE for when 20261025100000 is applied (add this case then, it cannot run today):
-- decide_technician_leave's approval writes technician_availability per day in the range as an
-- upsert: a day with NO existing row is a plain INSERT (status='leave') — the trigger's "after
-- insert or update of status, date ... when (new.status='leave')" fires unconditionally on
-- INSERT, so this day WILL release any already-assigned AMC visit. A day that already carried a
-- pre-existing 'leave' row (only possible if an admin had created it directly first — any other
-- pre-existing status aborts the whole approval before any write) instead takes the ON CONFLICT
-- DO NOTHING branch — no write at all, so no trigger fires for that day either (the day was
-- already 'leave' before this approval; the release path, if applicable, already ran whenever
-- that admin-direct row was first created). Once that migration is applied, assert: approving a
-- request for a NEW leave day on a technician with a future assigned AMC visit releases it
-- (trigger fired on INSERT); a day that was already an admin-direct 'leave' row is untouched by
-- the approval (DO NOTHING, confirmed by the test below that it survives revoke unlinked).
--
-- KPI TEST DESIGN: settings.lead_work_days = {1} (Monday only) for this test org, and
-- settings.attendance_reward_min_present_ratio is left at its default 0.5. March 2026's Mondays
-- are 2, 9, 16, 23, 30 — but NO technician ever attends on 2026-03-16, so it is a genuine
-- organisation-wide closure (a company holiday, say) and drops out of org_days entirely, even
-- though it is a working weekday. The real organisation working days this month are therefore
-- {02, 09, 23, 30} — four days (n = 4; ceil(4 * 0.5) = 2 minimum real attendance days). All KPI
-- cases use these fixed 2026-03 dates so they do not depend on when the rehearsal actually runs.
do $t$
declare
  res text := '';
  v_org uuid; v_master uuid;
  v_t1 uuid; v_t1id uuid; v_t2 uuid; v_t2id uuid; v_ctrl uuid; v_ctrlid uuid;
  v_sun uuid; v_sunid uuid; v_extra uuid; v_extraid uuid; v_zero uuid; v_zeroid uuid;
  v_overlap uuid; v_overlapid uuid; v_closureleave uuid; v_closureleaveid uuid;
  v_below uuid; v_belowid uuid; v_admin uuid; v_adminid uuid; v_started uuid; v_startedid uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_req uuid; v_req2 uuid; v_req_sun uuid; v_req_zero uuid; v_req_overlap uuid;
  v_req_closureleave uuid; v_req_below uuid; v_req_admin uuid; v_req_started uuid;
  v_reject uuid; v_cancel uuid; v_revoke uuid;
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
  insert into settings (org_id, leave_notice_days, lead_work_days) values (v_org, 3, '{1}');

  v_master := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_master, 'authenticated', 'authenticated', 'leave-master@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_master, v_org, '__TEST_ master', 'master');

  v_t1 := gen_random_uuid(); v_t2 := gen_random_uuid(); v_ctrl := gen_random_uuid();
  v_sun := gen_random_uuid(); v_extra := gen_random_uuid(); v_zero := gen_random_uuid();
  v_overlap := gen_random_uuid(); v_closureleave := gen_random_uuid(); v_below := gen_random_uuid();
  v_admin := gen_random_uuid(); v_started := gen_random_uuid();
  insert into auth.users (id, aud, role, email) values (v_t1, 'authenticated', 'authenticated', 'leave-t1@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_t2, 'authenticated', 'authenticated', 'leave-t2@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_ctrl, 'authenticated', 'authenticated', 'leave-ctrl@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_sun, 'authenticated', 'authenticated', 'leave-sun@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_extra, 'authenticated', 'authenticated', 'leave-extra@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_zero, 'authenticated', 'authenticated', 'leave-zero@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_overlap, 'authenticated', 'authenticated', 'leave-overlap@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_closureleave, 'authenticated', 'authenticated', 'leave-closure@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_below, 'authenticated', 'authenticated', 'leave-below@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_admin, 'authenticated', 'authenticated', 'leave-admin@test.invalid');
  insert into auth.users (id, aud, role, email) values (v_started, 'authenticated', 'authenticated', 'leave-started@test.invalid');
  insert into profiles (id, org_id, full_name, role) values (v_t1, v_org, '__TEST_ tech1', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_t2, v_org, '__TEST_ tech2', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_ctrl, v_org, '__TEST_ ctrl', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_sun, v_org, '__TEST_ sun', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_extra, v_org, '__TEST_ extra', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_zero, v_org, '__TEST_ zero', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_overlap, v_org, '__TEST_ overlap', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_closureleave, v_org, '__TEST_ closure', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_below, v_org, '__TEST_ below', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_admin, v_org, '__TEST_ admin', 'technician');
  insert into profiles (id, org_id, full_name, role) values (v_started, v_org, '__TEST_ started', 'technician');
  insert into technicians (org_id, profile_id) values (v_org, v_t1) returning id into v_t1id;
  insert into technicians (org_id, profile_id) values (v_org, v_t2) returning id into v_t2id;
  insert into technicians (org_id, profile_id) values (v_org, v_ctrl) returning id into v_ctrlid;
  insert into technicians (org_id, profile_id) values (v_org, v_sun) returning id into v_sunid;
  insert into technicians (org_id, profile_id) values (v_org, v_extra) returning id into v_extraid;
  insert into technicians (org_id, profile_id) values (v_org, v_zero) returning id into v_zeroid;
  insert into technicians (org_id, profile_id) values (v_org, v_overlap) returning id into v_overlapid;
  insert into technicians (org_id, profile_id) values (v_org, v_closureleave) returning id into v_closureleaveid;
  insert into technicians (org_id, profile_id) values (v_org, v_below) returning id into v_belowid;
  insert into technicians (org_id, profile_id) values (v_org, v_admin) returning id into v_adminid;
  insert into technicians (org_id, profile_id) values (v_org, v_started) returning id into v_startedid;

  -- ══ KPI exclusion (reward_candidates' per-day coverage) ══════════════════════════════════
  -- 2026-03-16 (a Monday) is a deliberate org-wide closure: NO technician attends it below, so
  -- it never becomes an org_day even though it is a working weekday. Real org_days = {02,09,23,30}.
  insert into attendance (org_id, technician_id, date, check_in_at, is_late) values
    -- ctrl / test (a): full attendance on every real org_day -> eligible despite the closure
    (v_org, v_ctrlid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    (v_org, v_ctrlid, '2026-03-30', '2026-03-30 09:00+05:30', false),
    -- t1: present 02/09/23, misses 30 -- will be protected (in-advance) leave
    (v_org, v_t1id, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_t1id, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- t2: same shortfall, will be LATE (not protected) leave on 2026-03-30
    (v_org, v_t2id, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_t2id, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- sun: same shortfall, protected leave on a SUNDAY (2026-03-29) only -- not an org_day
    (v_org, v_sunid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_sunid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_sunid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- extra: same shortfall, EXTRA attendance on a non-working day (2026-03-31, a Tuesday)
    (v_org, v_extraid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    (v_org, v_extraid, '2026-03-31', '2026-03-31 09:00+05:30', false),
    -- overlap / test (b): present 02/09/23 -- 23 will ALSO be inside a protected leave range,
    -- and 30 is missing entirely (neither attended nor covered)
    (v_org, v_overlapid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_overlapid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_overlapid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- closureleave / test (c): present 02/09/23, misses 30 -- protected leave covers the
    -- CLOSURE day (2026-03-16) only, which is not an org_day and so cannot help
    (v_org, v_closureleaveid, '2026-03-02', '2026-03-02 09:00+05:30', false),
    (v_org, v_closureleaveid, '2026-03-09', '2026-03-09 09:00+05:30', false),
    (v_org, v_closureleaveid, '2026-03-23', '2026-03-23 09:00+05:30', false),
    -- below / test (d): exactly 1 of the 4 real org_days attended (below the ceil(4*0.5)=2
    -- minimum), with protected leave covering the other 3
    (v_org, v_belowid, '2026-03-02', '2026-03-02 09:00+05:30', false);
    -- zero / test (d) extreme: no attendance at all, inserted below via protected leave only.

  -- t1: requested 2026-03-01 for 2026-03-30 (well ahead of leave_notice_days=3) -> protected
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t1id, '2026-03-30', '2026-03-30', v_t1, '2026-03-01 10:00+05:30')
    returning id into v_req;
  -- t2: requested 2026-03-29 for 2026-03-30 (1 day's notice, < 3) -> NOT protected = "late"
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_t2id, '2026-03-30', '2026-03-30', v_t2, '2026-03-29 10:00+05:30')
    returning id into v_req2;
  -- sun: requested well ahead, but for 2026-03-29 (Sunday) only
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_sunid, '2026-03-29', '2026-03-29', v_sun, '2026-02-01 10:00+05:30')
    returning id into v_req_sun;
  -- zero: requested well ahead, 2026-03-01..2026-03-30 (29-day span) -- test (d) extreme: zero
  -- real attendance, every real org_day covered by leave alone
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_zeroid, '2026-03-01', '2026-03-30', v_zero, '2026-02-01 10:00+05:30')
    returning id into v_req_zero;
  -- overlap: requested well ahead, for 2026-03-23 only -- the SAME day overlap already attends
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_overlapid, '2026-03-23', '2026-03-23', v_overlap, '2026-02-01 10:00+05:30')
    returning id into v_req_overlap;
  -- closureleave: requested well ahead, for 2026-03-16 only (the closure day)
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_closureleaveid, '2026-03-16', '2026-03-16', v_closureleave, '2026-02-01 10:00+05:30')
    returning id into v_req_closureleave;
  -- below: requested well ahead, 2026-03-09..2026-03-30 -- covers org_days 09/23/30, nothing on 02
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_belowid, '2026-03-09', '2026-03-30', v_below, '2026-02-01 10:00+05:30')
    returning id into v_req_below;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select * into v_row from decide_technician_leave(v_req, 'approved');
  res := res || E'\n' || format('t1 (in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req2, 'approved');
  res := res || E'\n' || format('t2 (late) approved, protected (expect false): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_sun, 'approved');
  res := res || E'\n' || format('sun (Sunday only, in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_zero, 'approved');
  res := res || E'\n' || format('zero (whole month, in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_overlap, 'approved');
  res := res || E'\n' || format('overlap (same day as attendance, in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_closureleave, 'approved');
  res := res || E'\n' || format('closureleave (closure day, in advance) approved, protected (expect true): %s', v_row.protected);
  select * into v_row from decide_technician_leave(v_req_below, 'approved');
  res := res || E'\n' || format('below (covers 3 of 4 real days, in advance) approved, protected (expect true): %s', v_row.protected);

  -- test 1: in-advance protected leave + attendance on every other real org_day -> eligible
  select count(*) = 1 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t1id;
  res := res || E'\n' || format('test1 protected t1 eligible (expect true): %s', v_ok);

  -- test 2: same shortfall, late (not in-advance) leave -> not eligible
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_t2id;
  res := res || E'\n' || format('test2 late t2 NOT eligible (expect true): %s', v_ok);

  -- test 3: protected leave on a Sunday does not count
  select technician_protected_leave_days(v_org, v_sunid, '2026-03-01', '2026-03-31') = 0 into v_ok;
  res := res || E'\n' || format('test3 Sunday-only protected leave counts as 0 days (expect true): %s', v_ok);
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_sunid;
  res := res || E'\n' || format('test3 sun NOT eligible -- Sunday leave does not cover the missing day (expect true): %s', v_ok);

  -- test 4: extra attendance on a non-working day does not cover the missing working day
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_extraid;
  res := res || E'\n' || format('test4 extra NOT eligible -- non-working-day attendance does not substitute (expect true): %s', v_ok);

  -- test (a): a closure day (working weekday, zero org-wide attendance) never becomes an
  -- org_day -- full attendance on the remaining real days is eligible
  select count(*) = 1 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_ctrlid;
  res := res || E'\n' || format('testA ctrl eligible despite the 2026-03-16 closure (expect true): %s', v_ok);

  -- test (b): attendance AND protected leave on the SAME day (2026-03-23), plus one genuinely
  -- missed day (2026-03-30) -- per-day OR coverage = 3 of 4, not eligible (naive addition of
  -- attended_days(3) + raw protected-day-count(1) would wrongly total 4 = n)
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_overlapid;
  res := res || E'\n' || format('testB overlap NOT eligible -- same-day double count does not help (expect true): %s', v_ok);

  -- test (c): protected leave on the closure day (2026-03-16, not an org_day) does not cover
  -- the genuinely missed day (2026-03-30)
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_closureleaveid;
  res := res || E'\n' || format('testC closureleave NOT eligible -- leave on a closure day does not help (expect true): %s', v_ok);

  -- test (d): below the minimum-present ratio (1 of 4 real days attended; ceil(4*0.5)=2 required)
  -- even though protected leave covers every other real day -- not eligible
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_belowid;
  res := res || E'\n' || format('testD below-ratio NOT eligible -- 1 real day < minimum 2 (expect true): %s', v_ok);

  -- test 5 / (d) extreme: zero real attendance, even with every real org_day covered by
  -- protected leave, is not eligible (0 attended days < minimum 2)
  select technician_protected_leave_days(v_org, v_zeroid, '2026-03-01', '2026-03-31') = 4 into v_ok;
  res := res || E'\n' || format('test5 zero''s leave covers all 4 real org_days (expect true): %s', v_ok);
  select count(*) = 0 into v_ok from reward_candidates(v_org, '2026-03-01') where category = 'attendance' and technician_id = v_zeroid;
  res := res || E'\n' || format('test5 zero NOT eligible -- zero real attendance (expect true): %s', v_ok);

  -- test (e): a cross-org call of technician_protected_leave_days is refused (master is in
  -- v_org, not the real org fetched for the fingerprint above)
  begin
    perform technician_protected_leave_days(v_real_org, v_t1id, '2026-03-01', '2026-03-31');
    res := res || E'\n' || 'testE cross-org technician_protected_leave_days: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'testE cross-org technician_protected_leave_days: rejected ('||sqlerrm||')';
  end;

  select count(*) into v_n from technician_availability where leave_request_id = v_req and status = 'leave' and protected;
  res := res || E'\n' || format('t1 approved leave materialised as protected technician_availability row (expect 1): %s', v_n);

  -- technician_protected_leave_days(p_from > p_to) returns 0, never errors
  select technician_protected_leave_days(v_org, v_t1id, '2026-04-01', '2026-03-01') = 0 into v_ok;
  res := res || E'\n' || format('p_from > p_to returns 0 (expect true): %s', v_ok);

  -- a request creates its notification row (role-targeted, to master/operation_admin)
  select count(*) > 0 into v_ok from notifications where ref_id = v_req and type = 'technician_leave_requested';
  res := res || E'\n' || format('approved-request notification row exists for t1''s request (expect true): %s', v_ok);
  select count(*) > 0 into v_ok from notifications where ref_id = v_req and type = 'technician_leave_approved';
  res := res || E'\n' || format('approval notification row exists (expect true): %s', v_ok);

  -- admin / "an admin-entered leave day inside an approved range survives revoke": a pre-existing
  -- technician_availability row (leave_request_id null, status='leave') on the exact day of a
  -- new request's range must be left alone by approval (ON CONFLICT DO NOTHING) and must NOT be
  -- deleted by a later revoke (revoke only deletes rows with leave_request_id = that request).
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_adminid, v_today + 50, 'leave');
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_adminid, v_today + 50, v_today + 50, v_admin, now())
    returning id into v_req_admin;
  select * into v_row from decide_technician_leave(v_req_admin, 'approved');
  select leave_request_id is null into v_ok from technician_availability where technician_id = v_adminid and date = v_today + 50;
  res := res || E'\n' || format('admin pre-existing leave row left unlinked by approval, ON CONFLICT DO NOTHING (expect true): %s', v_ok);
  select * into v_row from decide_technician_leave(v_req_admin, 'revoked', 'cover arranged');
  select count(*) = 1 into v_ok from technician_availability where technician_id = v_adminid and date = v_today + 50 and status = 'leave';
  res := res || E'\n' || format('admin pre-existing leave row survives revoke, still unlinked (expect true): %s', v_ok);

  -- already-started: a pending request whose start_date has passed cannot be approved, only rejected
  insert into technician_leave_requests (org_id, technician_id, start_date, end_date, requested_by, created_at)
    values (v_org, v_startedid, v_today - 5, v_today - 5, v_started, now() - interval '20 days')
    returning id into v_req_started;
  begin
    perform decide_technician_leave(v_req_started, 'approved', null);
    res := res || E'\n' || 'approving an already-started request: SUCCEEDED (bad)';
  exception when others then
    res := res || E'\n' || 'approving an already-started request: rejected ('||sqlerrm||')';
  end;
  select * into v_row from decide_technician_leave(v_req_started, 'rejected', 'started before anyone actioned it');
  res := res || E'\n' || format('already-started request can still be rejected: status (expect rejected): %s', v_row.status);

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
  select count(*) > 0 into v_ok from notifications where ref_id = v_reject and type = 'technician_leave_rejected';
  res := res || E'\n' || format('reject notification row exists (expect true): %s', v_ok);
  select * into v_row from decide_technician_leave(v_revoke, 'approved');
  res := res || E'\n' || format('pre-revoke approve: status (expect approved): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('pre-revoke: availability row exists (expect 1): %s', v_n);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_t1, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from cancel_technician_leave(v_cancel);
  res := res || E'\n' || format('t1 cancels own pending request: status (expect cancelled): %s', v_row.status);
  select count(*) > 0 into v_ok from notifications where ref_id = v_cancel and type = 'technician_leave_cancelled';
  res := res || E'\n' || format('cancel notification row exists (expect true): %s', v_ok);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select * into v_row from decide_technician_leave(v_revoke, 'revoked', 'cover arranged, leave withdrawn');
  res := res || E'\n' || format('revoke: status (expect revoked): %s', v_row.status);
  select count(*) into v_n from technician_availability where leave_request_id = v_revoke and status = 'leave';
  res := res || E'\n' || format('post-revoke: availability row removed (expect 0): %s', v_n);
  select count(*) > 0 into v_ok from notifications where ref_id = v_revoke and type = 'technician_leave_revoked';
  res := res || E'\n' || format('revoke notification row exists (expect true): %s', v_ok);
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
