-- Rolled-back test for 20261120100000_customer_link_otp.sql (request_customer_link_code /
-- verify_customer_link_code). The runner concatenates that migration file in front of this block
-- in ONE transaction; this block ends in RAISE EXCEPTION, so nothing is committed regardless of
-- pass/fail. Throwaway __TEST_ organisation, users and customers only.
--
-- Role discipline: the two RPCs are SECURITY DEFINER and read auth.uid() off
-- request.jwt.claims, so each call needs `set local role authenticated` first. But
-- customer_link_otp_challenges/_send_log have NO select policy for ANY role (by design — see the
-- migration's own comment on that table) and whatsapp_outbox only grants staff, not a bare
-- authenticated customer — so every direct table read this test does to verify server-side state
-- must run back under this session's own (superuser) role, never while 'authenticated' is still
-- active. The pattern below is therefore: set local role authenticated -> call the RPC(s) ->
-- reset role -> read tables directly to verify -> repeat.
do $t$
declare
  res text := '';
  v_org uuid;
  v_user_a uuid := gen_random_uuid();
  v_user_b uuid := gen_random_uuid();
  v_user_c uuid := gen_random_uuid();
  v_user_e uuid := gen_random_uuid(); -- P10/P11: a fresh, never-linked user (v_user_a is used up after P7 links it)
  v_user_f uuid := gen_random_uuid(); -- P14: race-condition-fix regression (a separate customer, untouched by P1-P13)
  v_cust_race uuid;
  v_active_challenge_count int;
  v_cust_real uuid;
  v_cust_linked uuid;
  v_cust_test uuid;
  v_outbox_count_before int;
  v_outbox_count_after int;
  v_outbox_body text;
  v_result jsonb;
  v_result2 jsonb;
  v_challenge_id uuid;
  v_code text;
  v_salt text;
  v_profile_count int;
  v_primary_profile_id uuid;
  v_phone_verified boolean;
  i int;
begin
  insert into organizations(name) values ('__TEST_customer_link_otp_org') returning id into v_org;
  insert into auth.users(id, email) select x, '__test_' || x || '@example.invalid'
    from unnest(array[v_user_a, v_user_b, v_user_c, v_user_e, v_user_f]) x;

  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_real', '9000000011') returning id into v_cust_real;
  insert into profiles(id, org_id, full_name, role) values (v_user_c, v_org, '__TEST_already_linked', 'customer');
  insert into customers(org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_customer_linked', '9000000012', v_user_c) returning id into v_cust_linked;
  insert into customers(org_id, name, mobile, is_test) values (v_org, '__TEST_customer_flagged_test', '9000000013', true) returning id into v_cust_test;

  -- SECURITY REVIEW FIX (2026-11-20): is_customer_link_otp_enabled() now ALSO requires
  -- settings.wa_dispatch_v2_enabled = true somewhere (see that function's own comment) --
  -- without this, every call below would now fail with feature_disabled, since this test org's
  -- settings row defaults to v2 dispatch OFF like every other org's does.
  -- MUST run here, before the first set_config('request.jwt.claims', ...) call below: `settings`
  -- carries the generic audit_master_change trigger, which writes actor_id = auth.uid() with NO
  -- existence check against profiles (unlike audit_profile_changes on `profiles`, which defends
  -- against exactly this). `reset role` only resets the SQL role, not the request.jwt.claims GUC
  -- set_config leaves behind, so running this insert AFTER G0's set_config call left auth.uid()
  -- pointing at v_user_a, who has no profiles row yet -- an FK violation on audit_log, found by
  -- this project's own rehearsal gate the first time this insert was added.
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.settings set wa_dispatch_v2_enabled = true where org_id = v_org;

  -- Flag starts OFF by default (migration inserts enabled=false) — confirm the RPC refuses before
  -- turning it on for the rest of this test.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.request_customer_link_code('9000000011');
    res := res || E'\nFAIL G0 request_customer_link_code succeeded while the feature flag is OFF (default)';
  exception when others then
    res := res || E'\nok   G0 request_customer_link_code refuses while the feature flag is OFF (' || sqlerrm || ')';
  end;
  execute 'reset role';

  update public.customer_link_otp_settings set enabled = true where id = true;

  -- ===== G0b: the flag now reads OFF again if v2 dispatch is off even though the operator flag
  -- itself is on -- the CRITICAL operational-precondition fix (independent adversarial review,
  -- 2026-11-20): turning the feature on while v2 dispatch is off must never silently leave
  -- plaintext codes sitting in whatsapp_outbox; it must just keep showing "not available yet".
  -- Clearing request.jwt.claims before each raw `settings` write here (not just resetting role)
  -- is required for the same reason documented above the first settings insert: auth.uid() would
  -- otherwise still resolve to G0's/this block's own test user, who has no profiles row yet, and
  -- settings' generic audit_master_change trigger does not defend against that the way
  -- audit_profile_changes does. =====
  perform set_config('request.jwt.claims', 'null', true);
  update public.settings set wa_dispatch_v2_enabled = false where org_id = v_org;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_b, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.request_customer_link_code('9000000011');
    res := res || E'\nFAIL G0b request_customer_link_code succeeded with operator flag ON but wa_dispatch_v2_enabled OFF on every org';
  exception when others then
    res := res || E'\nok   G0b request_customer_link_code refuses when wa_dispatch_v2_enabled is off on every org, even with the operator flag on (' || sqlerrm || ')';
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);
  update public.settings set wa_dispatch_v2_enabled = true where org_id = v_org;

  -- ===== P1/P2/P3: no match / test customer / already-linked -> identical generic response,
  -- nothing written (checked after, back under this session's own role) =====
  select count(*) into v_outbox_count_before from public.whatsapp_outbox where org_id = v_org;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000099') into v_result;   -- P1: unknown number
  select public.request_customer_link_code('9000000013') into v_result2;  -- P2: test-flagged customer
  execute 'reset role';

  res := res || E'\n' || case when v_result ->> 'status' = 'ok' then 'ok   P1 unknown number returns the generic ok response' else 'FAIL P1 shape=' || v_result::text end;
  res := res || E'\n' || case when v_result2 = v_result then 'ok   P2 test customer returns the IDENTICAL response shape as an unknown number (no existence oracle)' else 'FAIL P2 response differs: ' || v_result2::text end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000012') into v_result2; -- P3: already-linked customer
  execute 'reset role';
  res := res || E'\n' || case when v_result2 = v_result then 'ok   P3 already-linked customer returns the IDENTICAL response shape (no existence/already-linked oracle)' else 'FAIL P3 response differs: ' || v_result2::text end;

  select count(*) into v_outbox_count_after from public.whatsapp_outbox where org_id = v_org;
  res := res || E'\n' || case when v_outbox_count_after = v_outbox_count_before then 'ok   P1-P3b no outbox row was created for any of unknown/test/already-linked' else 'FAIL P1-P3b outbox row leaked' end;

  -- ===== P4: exactly one unlinked, non-test customer -> same generic response, but a challenge +
  -- outbox row ARE created (observable only server-side, never from the RPC's own return value) =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000011') into v_result2;
  execute 'reset role';
  res := res || E'\n' || case when v_result2 = v_result then 'ok   P4 real unlinked customer ALSO returns the identical generic response' else 'FAIL P4 response differs: ' || v_result2::text end;

  select id, code_salt into v_challenge_id, v_salt
  from public.customer_link_otp_challenges where customer_id = v_cust_real and used_at is null and superseded_at is null;
  res := res || E'\n' || case when v_challenge_id is not null then 'ok   P4b a challenge row was created server-side for the real customer' else 'FAIL P4b no challenge row created' end;

  select o.payload ->> 'body' into v_outbox_body
  from public.whatsapp_outbox o
  join public.customer_link_otp_challenges c on c.outbox_id = o.id where c.id = v_challenge_id;
  res := res || E'\n' || case when exists (
    select 1 from public.whatsapp_outbox o join public.customer_link_otp_challenges c on c.outbox_id = o.id
    where c.id = v_challenge_id and o.ref_type = 'customer_link_otp' and o.ref_id = v_challenge_id and o.status = 'pending'
  ) then 'ok   P4c outbox row has ref_type/ref_id/status wired correctly' else 'FAIL P4c' end;

  -- extract the plaintext code the way only this test (never the app) can, by re-deriving it:
  -- the test knows the DB-generated code only by reading code_hash/code_salt back and comparing
  -- against candidate codes is impractical here, so instead we recover it from the outbox body
  -- (this test's own privileged read, standing in for "we know what code was actually sent").
  v_code := substring(v_outbox_body from '^\d{6}');
  res := res || E'\n' || case when v_code ~ '^\d{6}$' then 'ok   P4d a 6-digit code is present in the outbox message body' else 'FAIL P4d could not find a 6-digit code in: ' || coalesce(v_outbox_body, '(null)') end;

  -- ===== P5: wrong code decrements attempts_left, identical "invalid_or_expired" shape ========
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code('000000') into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' and (v_result ->> 'attempts_left')::int = 4
    then 'ok   P5 one wrong guess: status invalid_or_expired, attempts_left=4' else 'FAIL P5 ' || v_result::text end;

  -- ===== P6: 4 more wrong guesses exhaust the 5-attempt cap; the 6th is also invalid_or_expired/0 =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  for i in 1..4 loop
    select public.verify_customer_link_code('111111') into v_result;
  end loop;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' and (v_result ->> 'attempts_left')::int = 0
    then 'ok   P6 after 5 total wrong guesses, attempts_left=0' else 'FAIL P6 ' || v_result::text end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result; -- even the CORRECT code, once locked
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' and (v_result ->> 'attempts_left')::int = 0
    then 'ok   P6b a locked challenge refuses even the correct code' else 'FAIL P6b ' || v_result::text end;

  -- ===== P7: a fresh request supersedes the locked challenge; the NEW correct code links ======
  -- Backdate user A's own send-log rows first (this session's own role, never while
  -- 'authenticated') so THIS test's intentionally-rapid-fire request isn't itself caught by the
  -- very cooldown P11 below exists to prove — real callers are naturally seconds-to-minutes
  -- apart, this test harness is not.
  update public.customer_link_otp_send_log set created_at = created_at - interval '10 minutes' where user_id = v_user_a;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000011') into v_result;
  execute 'reset role';

  select id, code_salt into v_challenge_id, v_salt
  from public.customer_link_otp_challenges where customer_id = v_cust_real and used_at is null and superseded_at is null;
  select o.payload ->> 'body' into v_outbox_body from public.whatsapp_outbox o where o.id = (select outbox_id from public.customer_link_otp_challenges where id = v_challenge_id);
  v_code := substring(v_outbox_body from '^\d{6}');

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'linked' then 'ok   P7 correct code on a fresh challenge links successfully' else 'FAIL P7 ' || v_result::text end;

  select primary_profile_id, phone_verified into v_primary_profile_id, v_phone_verified from public.customers where id = v_cust_real;
  res := res || E'\n' || case when v_primary_profile_id = v_user_a then 'ok   P7b customers.primary_profile_id now points at the verifying user' else 'FAIL P7b' end;
  res := res || E'\n' || case when v_phone_verified then 'ok   P7c customers.phone_verified set true' else 'FAIL P7c' end;
  select count(*) into v_profile_count from public.profiles where id = v_user_a and org_id = v_org and role = 'customer';
  res := res || E'\n' || case when v_profile_count = 1 then 'ok   P7d exactly one profiles row created for the verifying user' else 'FAIL P7d count=' || v_profile_count end;

  -- ===== P8: replay of the SAME (now-used) code fails identically, never "already used" ======
  -- By this point user A already has a profiles row (P7 just created it), so this call is
  -- actually exercising TWO defenses stacked on top of each other: the "caller already has a
  -- profile" guard (which both RPCs check first, and raises — the caller's own state, not an
  -- oracle about anyone else) AND, if that guard were ever removed or bypassed, the challenge's
  -- own used_at check (returns invalid_or_expired). Either outcome proves the replay cannot
  -- succeed a second time; this test accepts both rather than coupling itself to which guard
  -- fires first.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    select public.verify_customer_link_code(v_code) into v_result;
    res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' then 'ok   P8 replaying an already-used code is refused with the SAME generic shape' else 'FAIL P8 ' || v_result::text end;
  exception when others then
    res := res || E'\n' || case when sqlerrm like 'cannot_verify_code: profile_exists%' then 'ok   P8 replay refused because the caller is already linked (profile_exists) -- cannot succeed twice either way' else 'FAIL P8 unexpected error: ' || sqlerrm end;
  end;
  execute 'reset role';

  -- ===== P9: a DIFFERENT authenticated user (B) has no active challenge of their own -> the
  -- same generic shape with the DEFAULT attempts_left (5), never user A's exhausted/active state,
  -- and never able to ride in on user A's challenge =====
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_b, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code('123456') into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' and (v_result ->> 'attempts_left')::int = 5
    then 'ok   P9 a second user with no challenge of their own gets the default attempts_left (never another user''s state)' else 'FAIL P9 ' || v_result::text end;

  -- ===== P10: expired challenge behaves identically to a wrong/no challenge =====
  -- A fresh user (v_user_a is used up — it already has a profile after P7) requests a code for
  -- the SAME real customer. request_customer_link_code's own "supersede any existing active
  -- challenge for this customer" step means this also re-proves that rule works across users,
  -- not just across repeat requests from one user.
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_e, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000011') into v_result; -- cooldown/rate limits aside, see P11-13 below for those
  execute 'reset role';

  -- Force the fresh challenge to look expired (direct table write — this test's own setup, not
  -- something either RPC exposes) and re-check it is refused identically.
  update public.customer_link_otp_challenges set expires_at = clock_timestamp() - interval '1 minute'
  where customer_id = v_cust_real and used_at is null and superseded_at is null;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_e, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code('999999') into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'invalid_or_expired' and (v_result ->> 'attempts_left')::int = 5
    then 'ok   P10 an expired challenge is refused with the SAME generic shape (default attempts_left)' else 'FAIL P10 ' || v_result::text end;

  -- ===== P11: cooldown — immediately repeating a request from the SAME user is silently a no-op
  -- (still the generic response, but no new outbox row) =====
  select count(*) into v_outbox_count_before from public.whatsapp_outbox where org_id = v_org;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_e, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000011') into v_result; -- same user, same number, right after P10's request
  execute 'reset role';
  select count(*) into v_outbox_count_after from public.whatsapp_outbox where org_id = v_org;
  res := res || E'\n' || case when v_outbox_count_after = v_outbox_count_before then 'ok   P11 a repeat request inside the 30s cooldown creates no new outbox row' else 'FAIL P11 cooldown did not hold' end;

  -- ===== P12: per-phone rate limit — a DIFFERENT user hammering the SAME number is still capped
  -- (3 sent/hour per phone), independent of the per-user cap =====
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_phonelimit', '9000000021') returning id into v_cust_real;
  for i in 1..5 loop
    perform set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.request_customer_link_code('9000000021');
    -- avoid the per-this-new-user cooldown being the thing that blocks it, not the per-phone cap:
    -- each iteration is a brand new random user_id, so only the per-phone counter can be at play.
    execute 'reset role';
  end loop;
  select count(*) into v_outbox_count_after from public.customer_link_otp_send_log where phone_hash = encode(extensions.digest('9000000021', 'sha256'), 'hex') and decision = 'sent';
  res := res || E'\n' || case when v_outbox_count_after = 3 then 'ok   P12 per-phone cap holds at exactly 3 sent, even across 5 distinct users hitting the same number' else 'FAIL P12 sent=' || v_outbox_count_after end;

  -- ===== P13: per-user rate limit — the SAME user requesting codes for 6 DIFFERENT numbers in
  -- one hour is capped at 5 sent (independent of each number's own per-phone cap) =====
  declare
    v_user_d uuid := gen_random_uuid();
    v_sent_count int;
  begin
    insert into auth.users(id, email) values (v_user_d, '__test_' || v_user_d || '@example.invalid');
    for i in 1..6 loop
      insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_userlimit_' || i, '90000003' || lpad(i::text, 2, '0'));
    end loop;
    -- One request per iteration, with role reset and this user's log rows backdated by (7-i)
    -- minutes BETWEEN each one (under this session's own role, never while 'authenticated') —
    -- real callers are naturally well over 30s apart; this loop runs in milliseconds, so without
    -- backdating every call after the first would be eaten by the cooldown instead of the cap
    -- this test is actually trying to prove. All 6 timestamps stay well inside the 1-hour window.
    for i in 1..6 loop
      perform set_config('request.jwt.claims', json_build_object('sub', v_user_d, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform public.request_customer_link_code('90000003' || lpad(i::text, 2, '0'));
      execute 'reset role';
      update public.customer_link_otp_send_log set created_at = created_at - (interval '1 minute' * (7 - i)) where user_id = v_user_d;
    end loop;
    select count(*) into v_sent_count from public.customer_link_otp_send_log where user_id = v_user_d and decision = 'sent';
    res := res || E'\n' || case when v_sent_count = 5 then 'ok   P13 per-user cap holds at exactly 5 sent across 6 distinct numbers' else 'FAIL P13 sent=' || v_sent_count end;
  end;

  -- ===== P14: race-condition fix regression (independent adversarial review, 2026-11-20, HIGH) =====
  -- True concurrent-transaction testing is not possible inside this single rehearsal transaction
  -- (everything here is strictly serial from Postgres's own point of view -- the advisory lock
  -- and the unique-constraint exception handler it backs up exist specifically for genuinely
  -- concurrent callers, which this framework cannot simulate). What IS verified here: the normal
  -- sequential supersede-then-insert path still behaves correctly after adding the advisory lock
  -- (no regression), and that at most one ACTIVE (not used, not superseded) challenge ever exists
  -- for a customer at a time, which is the exact invariant whose violation is what the race could
  -- have broken.
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_race', '9000000050') returning id into v_cust_race;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_f, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.request_customer_link_code('9000000050'); -- first request: creates challenge #1
  perform public.request_customer_link_code('9000000050'); -- second, sequential request for the SAME customer: must supersede #1 and create #2 cleanly, never raise
  execute 'reset role';

  select count(*) into v_active_challenge_count
  from public.customer_link_otp_challenges
  where customer_id = v_cust_race and used_at is null and superseded_at is null;
  res := res || E'\n' || case when v_active_challenge_count = 1
    then 'ok   P14 two sequential requests for the same customer leave exactly one active challenge (supersede still works after the advisory-lock fix)'
    else 'FAIL P14 active challenge count = ' || v_active_challenge_count end;

  res := res || E'\nINFO P14 note: the advisory lock + unique_violation exception handler this fixes a HIGH-severity'
    || ' enumeration oracle (concurrent requests for the same real customer could previously leak a raw'
    || ' Postgres error distinguishable from the generic response) exist specifically for genuinely'
    || ' CONCURRENT callers, which a single serial rehearsal transaction cannot reproduce -- this check'
    || ' only proves no regression in the normal sequential path.';

  -- ===== G1: anon cannot execute either RPC (defense-in-depth grant check, independent of the
  -- apply-time anon-exposure sweep) =====
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')
    then 'ok   G1 anon cannot execute request_customer_link_code' else 'FAIL G1 anon CAN execute request_customer_link_code' end;
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')
    then 'ok   G2 anon cannot execute verify_customer_link_code' else 'FAIL G2 anon CAN execute verify_customer_link_code' end;

  raise exception E'RESULTS:%', res;
end
$t$;
