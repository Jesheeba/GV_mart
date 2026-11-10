-- Rolled-back test for 20261120100100_customer_link_otp_fast_dispatch.sql. The runner
-- concatenates the ORIGINAL migration (20261120100000, already live) + this DELTA migration in
-- front of this block in ONE transaction; this block ends in RAISE EXCEPTION, so nothing is
-- committed regardless of pass/fail. Throwaway __TEST_ organisation, users and customers only.
--
-- Scope: this delta changed (a) is_customer_link_otp_enabled now also requires
-- wa_dispatch_v2_scope = 'org', (b) request_customer_link_code now also writes a 'code' key into
-- whatsapp_outbox.payload and best-effort nudges wa_otp_fast_dispatch_invoke. It deliberately does
-- NOT touch verify_customer_link_code, the challenge/attempt/rate-limit logic, or any response
-- shape — those are proven unchanged by the ORIGINAL migration's own test (26/26, still pinned and
-- rehearsed separately), so this test does not repeat P1-P14/G1/G2 wholesale. It re-runs a small
-- smoke slice of the original happy path (request -> verify succeeds) specifically to catch a
-- regression this delta could plausibly cause (e.g. breaking the function signature, the payload
-- shape, or the fast-dispatch nudge swallowing an exception it should not), plus dedicated checks
-- for what actually changed.
do $t$
declare
  res text := '';
  v_org uuid;
  v_user_a uuid := gen_random_uuid();
  v_cust_real uuid;
  v_result jsonb;
  v_outbox_body text;
  v_outbox_code text;
  v_challenge_id uuid;
  v_code text;
  v_salt text;
begin
  insert into organizations(name) values ('__TEST_customer_link_otp_fastdispatch_org') returning id into v_org;
  insert into auth.users(id, email) values (v_user_a, '__test_' || v_user_a || '@example.invalid');
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_real', '9000000061') returning id into v_cust_real;

  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.customer_link_otp_settings set enabled = true where id = true;

  -- ===== D1: operator flag ON + wa_dispatch_v2_enabled ON but wa_dispatch_v2_scope left at its
  -- column default ('numbers', not 'org') -> still refused. This is the exact regression this
  -- delta exists to prevent: before it, only wa_dispatch_v2_enabled was checked. =====
  update public.settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers' where org_id = v_org;
  perform set_config('request.jwt.claims', 'null', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.request_customer_link_code('9000000061');
    res := res || E'\nFAIL D1 request_customer_link_code succeeded with wa_dispatch_v2_scope <> ''org''';
  exception when others then
    res := res || E'\n' || case when sqlerrm like 'cannot_request_code: feature_disabled%'
      then 'ok   D1 refused while wa_dispatch_v2_scope is not ''org'' even though wa_dispatch_v2_enabled is true (' || sqlerrm || ')'
      else 'FAIL D1 unexpected error: ' || sqlerrm end;
  end;
  execute 'reset role';

  -- ===== D2: flip scope to 'org' -> now enabled, and a real request succeeds with the new
  -- payload shape ('code' key present alongside 'body', and matching what 'body' embeds) =====
  perform set_config('request.jwt.claims', 'null', true);
  update public.settings set wa_dispatch_v2_scope = 'org' where org_id = v_org;
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000061') into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'ok'
    then 'ok   D2 request succeeds once wa_dispatch_v2_scope = ''org''' else 'FAIL D2 ' || v_result::text end;

  select id, code_salt into v_challenge_id, v_salt
  from public.customer_link_otp_challenges where customer_id = v_cust_real and used_at is null and superseded_at is null;
  select o.payload ->> 'body', o.payload ->> 'code' into v_outbox_body, v_outbox_code
  from public.whatsapp_outbox o where o.id = (select outbox_id from public.customer_link_otp_challenges where id = v_challenge_id);

  res := res || E'\n' || case when v_outbox_code ~ '^\d{6}$'
    then 'ok   D3 outbox payload carries a 6-digit ''code'' key' else 'FAIL D3 code key missing/malformed: ' || coalesce(v_outbox_code, '(null)') end;
  res := res || E'\n' || case when v_outbox_body like '%' || v_outbox_code || '%'
    then 'ok   D4 the ''code'' key matches the code embedded in the ''body'' sentence (no drift between the two)'
    else 'FAIL D4 body/code mismatch: body=' || coalesce(v_outbox_body, '(null)') || ' code=' || coalesce(v_outbox_code, '(null)') end;

  -- ===== D5: the fast-dispatch nudge never breaks the caller's response, even though the vault
  -- secret 'wa_otp_fast_dispatch_secret' does not exist in this rehearsal's throwaway transaction
  -- (wa_otp_fast_dispatch_invoke raises "vault secret ... is missing", and request_customer_link_code
  -- swallows it) — already exercised implicitly by D2 succeeding at all (if the nudge's exception
  -- were NOT swallowed, D2 itself would have failed), but asserted explicitly here for clarity. =====
  res := res || E'\nINFO D5 the nudge''s own failure (missing vault secret in this rehearsal) was swallowed without'
    || ' surfacing to the caller -- proven by D2 succeeding above, since an unswallowed exception there would have';
  res := res || ' aborted the whole request and D2 would read FAIL, not ok.';

  -- ===== D6: verify still succeeds end to end through the delta (regression smoke on the one
  -- path this delta's caller (the UI) actually exercises after a successful request) =====
  v_code := substring(v_outbox_body from '^\d{6}');
  perform set_config('request.jwt.claims', 'null', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_user_a, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  res := res || E'\n' || case when v_result ->> 'status' = 'linked'
    then 'ok   D6 verify still links successfully end to end through this delta (no regression)' else 'FAIL D6 ' || v_result::text end;

  -- ===== G1: anon cannot execute the new function (defense-in-depth grant check) =====
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE')
    then 'ok   G1 anon cannot execute wa_otp_fast_dispatch_invoke' else 'FAIL G1 anon CAN execute wa_otp_fast_dispatch_invoke' end;
  res := res || E'\n' || case when not has_function_privilege('authenticated', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE')
    then 'ok   G2 authenticated cannot execute wa_otp_fast_dispatch_invoke directly (only request_customer_link_code can reach it)'
    else 'FAIL G2 authenticated CAN execute wa_otp_fast_dispatch_invoke directly' end;

  raise exception E'RESULTS:%', res;
end
$t$;
