-- Test for 20261121100150_customer_link_otp_respects_auto_link_block.sql. Run inside the
-- rehearsal wrapper's own transaction, AFTER the migration (and everything it depends on) has
-- been applied in the same transaction. Ends by raising an exception listing every assertion's
-- pass/fail, so nothing here ever commits regardless of outcome. Same role discipline as
-- customer_link_otp.test.sql: `set local role authenticated` around each RPC call, `reset role`
-- (and clear request.jwt.claims) before any direct table read/write.
do $t$
declare
  v_results text := '';
  v_org uuid;
  v_user_blocked uuid := gen_random_uuid();
  v_user_unblocked uuid := gen_random_uuid();
  v_user_relinked uuid := gen_random_uuid();
  v_user_relinked2 uuid := gen_random_uuid(); -- P4 uses a FRESH auth user: the 30s per-user send
                                               -- cooldown is scoped to user_id, not customer_id,
                                               -- and P3 already logged a 'sent' decision for
                                               -- v_user_relinked moments earlier in this same test
                                               -- -- reusing it would trip the cooldown and is not
                                               -- what P4 is testing (it tests the CUSTOMER's block
                                               -- being cleared, not the same user's retry timing).
  v_cust_blocked uuid;
  v_cust_unblocked uuid;
  v_cust_relink uuid;
  v_result_blocked jsonb;
  v_result_nonexistent jsonb;
  v_result jsonb;
  v_challenge_id uuid;
  v_code text;
  v_salt text;
  v_row record;
  v_outbox_count int;
  v_send_log_decision text;
begin
  insert into organizations(name) values ('__TEST_otp_auto_link_block_org') returning id into v_org;
  insert into auth.users(id, email) select x, '__test_' || x || '@example.invalid'
    from unnest(array[v_user_blocked, v_user_unblocked, v_user_relinked, v_user_relinked2]) x;

  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'org' where org_id = v_org;
  update public.customer_link_otp_settings set enabled = true where id = true;

  -- Three customers, same shape as the base test file: unlinked, not test-flagged. One already
  -- carries auto_link_blocked_at (simulating a master's prior unlink), one does not, one will be
  -- "relinked" mid-test (block cleared, same effect as admin_link_customer_google_account's own
  -- clearing update, which this test does not call directly -- out of scope to touch -- but
  -- whose END STATE it reproduces to prove the OTP path reacts to it).
  insert into customers (org_id, name, mobile, auto_link_blocked_at, auto_link_blocked_by)
  values (v_org, '__TEST_customer_blocked', '9000000091', clock_timestamp() - interval '1 hour', null)
  returning id into v_cust_blocked;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_customer_unblocked', '9000000092') returning id into v_cust_unblocked;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_customer_relink', '9000000093') returning id into v_cust_relink;

  -- G0: the migration's own assertions already prove prosrc contains the new checks; restated
  -- behaviourally here.
  v_results := v_results || 'G0 ok: setup complete (migration assertions already proved the source change)' || E'\n';

  ----------------------------------------------------------------------------
  -- P1: a BLOCKED customer's request returns the generic response and writes nothing new beyond
  -- a 'no_match' send-log row -- no challenge, no outbox row.
  ----------------------------------------------------------------------------
  select count(*) into v_outbox_count from public.whatsapp_outbox where org_id = v_org;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_blocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000091') into v_result_blocked;   -- blocked customer's real number
  select public.request_customer_link_code('9000000000') into v_result_nonexistent; -- a number matching no customer at all
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result_blocked = jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.') then
    v_results := v_results || 'P1a ok: blocked customer gets the generic response' || E'\n';
  else
    v_results := v_results || format('P1a FAIL: blocked customer got %s', v_result_blocked) || E'\n';
  end if;

  if v_result_blocked = v_result_nonexistent then
    v_results := v_results || 'P1b ok: blocked-customer response is byte-identical to a nonexistent-phone response (no new oracle)' || E'\n';
  else
    v_results := v_results || format('P1b FAIL: responses differ -- blocked=%s nonexistent=%s', v_result_blocked, v_result_nonexistent) || E'\n';
  end if;

  if not exists (select 1 from public.customer_link_otp_challenges where customer_id = v_cust_blocked) then
    v_results := v_results || 'P1c ok: blocked customer -- no challenge row created' || E'\n';
  else
    v_results := v_results || 'P1c FAIL: a challenge row was created for a blocked customer' || E'\n';
  end if;

  select count(*) into v_outbox_count from public.whatsapp_outbox where org_id = v_org;
  if v_outbox_count = 0 then
    v_results := v_results || 'P1d ok: no outbox row created for the blocked customer''s request' || E'\n';
  else
    v_results := v_results || format('P1d FAIL: %s outbox row(s) created', v_outbox_count) || E'\n';
  end if;

  select decision into v_send_log_decision from public.customer_link_otp_send_log
  where phone_hash = encode(digest('9000000091', 'sha256'), 'hex') order by created_at desc limit 1;
  if v_send_log_decision = 'no_match' then
    v_results := v_results || 'P1e ok: send-log decision for the blocked customer is ''no_match'' -- same as any other non-matching/ineligible phone' || E'\n';
  else
    v_results := v_results || format('P1e FAIL: send-log decision was %s, expected no_match', v_send_log_decision) || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P2: UNBLOCKED customer -- full request+verify flow works unchanged (the new OR condition
  -- must never trip for a customer who isn't blocked).
  ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_unblocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000092') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id, code_salt into v_challenge_id, v_salt from public.customer_link_otp_challenges
  where customer_id = v_cust_unblocked and used_at is null and superseded_at is null;

  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'P2a ok: unblocked customer -- request created a challenge + outbox row as normal' || E'\n';
  else
    v_results := v_results || 'P2a FAIL: unblocked customer''s request did not create the expected challenge/outbox row' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_unblocked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked') then
    v_results := v_results || 'P2b ok: unblocked customer -- verify with the real code links normally, unchanged behaviour' || E'\n';
  else
    v_results := v_results || format('P2b FAIL: unblocked customer verify returned %s', v_result) || E'\n';
  end if;

  if (select primary_profile_id from public.customers where id = v_cust_unblocked) = v_user_unblocked then
    v_results := v_results || 'P2c ok: unblocked customer is actually linked in the customers table' || E'\n';
  else
    v_results := v_results || 'P2c FAIL: unblocked customer was not actually linked' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P3: a customer who becomes blocked IN BETWEEN request and verify (a master unlinks them
  -- mid-flow) -- verify must refuse with the same collapsed response every other race-loss case
  -- already returns, and must NOT link.
  ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000093') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from public.customer_link_otp_challenges
  where customer_id = v_cust_relink and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  -- Simulate the master unlinking this customer right now, between request and verify -- the
  -- exact column/value admin_unlink_customer_google_account's own live definition sets (reproduced
  -- as an end state here, not by calling that function, which is out of this feature's scope to
  -- touch).
  update public.customers set auto_link_blocked_at = clock_timestamp(), auto_link_blocked_by = null where id = v_cust_relink;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0) then
    v_results := v_results || 'P3a ok: a customer blocked between request and verify gets the same collapsed invalid_or_expired/0 response as any other race loss' || E'\n';
  else
    v_results := v_results || format('P3a FAIL: expected invalid_or_expired/0, got %s', v_result) || E'\n';
  end if;

  if (select primary_profile_id from public.customers where id = v_cust_relink) is null then
    v_results := v_results || 'P3b ok: the blocked-mid-flow customer was NOT linked' || E'\n';
  else
    v_results := v_results || 'P3b FAIL: the blocked-mid-flow customer WAS linked -- the guard did not hold' || E'\n';
  end if;

  if not exists (select 1 from public.profiles where id = v_user_relinked) then
    v_results := v_results || 'P3c ok: no profiles row was created for the blocked-mid-flow user' || E'\n';
  else
    v_results := v_results || 'P3c FAIL: a profiles row was created despite the block' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- P4: once the block is cleared (the end state admin_link_customer_google_account's own relink
  -- produces -- reproduced here, not by calling that function), OTP works again for this customer.
  ----------------------------------------------------------------------------
  update public.customers set auto_link_blocked_at = null, auto_link_blocked_by = null where id = v_cust_relink;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000093') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from public.customer_link_otp_challenges
  where customer_id = v_cust_relink and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from public.whatsapp_outbox
  where ref_type = 'customer_link_otp' and ref_id = v_challenge_id;

  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'P4a ok: once unblocked, a fresh request succeeds normally again' || E'\n';
  else
    v_results := v_results || 'P4a FAIL: once unblocked, request did not create a fresh challenge/outbox row' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_user_relinked2, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked')
     and (select primary_profile_id from public.customers where id = v_cust_relink) = v_user_relinked2 then
    v_results := v_results || 'P4b ok: once unblocked, verify links normally -- OTP works again for this customer' || E'\n';
  else
    v_results := v_results || format('P4b FAIL: once unblocked, verify returned %s', v_result) || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$t$;
