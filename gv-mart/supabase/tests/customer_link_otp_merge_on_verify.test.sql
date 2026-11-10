-- Test for 20261130100100_customer_link_otp_merge_on_verify.sql. Run inside the rehearsal
-- wrapper's own transaction, after the migration (and everything it depends on) has been applied
-- in the same transaction. Ends by raising an exception listing every assertion's pass/fail, so
-- nothing here ever commits regardless of outcome. Same role-switch convention as the other
-- customer_link_otp tests: `set local role authenticated` + request.jwt.claims around each RPC
-- call, cleared before any direct table read/write.
do $t$
declare
  v_results text := '';
  v_org uuid;
  -- scenario users
  v_u_merge uuid := gen_random_uuid();
  v_u_claim uuid := gen_random_uuid();
  v_u_ambiguous uuid := gen_random_uuid();
  v_u_linked_elsewhere uuid := gen_random_uuid();
  v_u_claim_race uuid := gen_random_uuid();
  v_u_merge_race uuid := gen_random_uuid();
  v_u_no_profile uuid := gen_random_uuid();
  v_u_has_records uuid := gen_random_uuid();
  v_u_someone_else uuid := gen_random_uuid();
  -- scenario customers
  v_auto_merge uuid; v_real_merge_target uuid;
  v_auto_claim uuid;
  v_auto_ambiguous uuid; v_real_amb_1 uuid; v_real_amb_2 uuid;
  v_auto_linked_elsewhere uuid; v_real_taken uuid;
  v_auto_claim_race uuid; v_racer_customer uuid;
  v_auto_merge_race uuid; v_real_merge_race_target uuid;
  v_no_profile_target uuid;
  v_auto_has_records uuid; v_real_for_has_records uuid;
  v_result jsonb;
  v_code text;
  v_challenge_id uuid;
  v_row record;
  v_eligible boolean;
begin
  insert into organizations(name) values ('__TEST_otp_merge_on_verify') returning id into v_org;
  insert into auth.users(id, email) select x, '__test_' || x || '@example.invalid'
    from unnest(array[v_u_merge, v_u_claim, v_u_ambiguous, v_u_linked_elsewhere, v_u_claim_race, v_u_merge_race, v_u_no_profile, v_u_has_records, v_u_someone_else]) x;

  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  update public.settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'org' where org_id = v_org;
  update public.customer_link_otp_settings set enabled = true where id = true;

  ----------------------------------------------------------------------------
  -- Scenario A: MERGE -- caller has an empty auto customer, exactly one eligible match.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_merge, v_org, '__TEST_auto_merge', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_merge', 'customer_app', v_u_merge, 'merge@example.invalid')
  returning id into v_auto_merge;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_real_merge_target', '9000000101') returning id into v_real_merge_target;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_merge, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000101') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.') then
    v_results := v_results || 'A1 ok: relaxed caller (empty auto customer) is let through, generic response' || E'\n';
  else
    v_results := v_results || format('A1 FAIL: %s', v_result) || E'\n';
  end if;

  select id into v_challenge_id from customer_link_otp_challenges where customer_id = v_real_merge_target and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from whatsapp_outbox where ref_type='customer_link_otp' and ref_id = v_challenge_id;
  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'A2 ok: challenge targets the matched OTHER customer' || E'\n';
  else
    v_results := v_results || 'A2 FAIL: no challenge/outbox row targeting the matched customer' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_merge, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked') then
    v_results := v_results || 'A3 ok: verify succeeds, status linked' || E'\n';
  else
    v_results := v_results || format('A3 FAIL: %s', v_result) || E'\n';
  end if;

  select * into v_row from customers where id = v_real_merge_target;
  if v_row.primary_profile_id = v_u_merge and v_row.phone_verified = true then
    v_results := v_results || 'A4 ok: matched customer now linked to the caller, phone_verified true' || E'\n';
  else
    v_results := v_results || format('A4 FAIL: matched customer state wrong -- %s', v_row) || E'\n';
  end if;

  select * into v_row from customers where id = v_auto_merge;
  if v_row.primary_profile_id is null and v_row.archived_at is not null then
    v_results := v_results || 'A5 ok: auto customer archived, NOT deleted, link cleared' || E'\n';
  else
    v_results := v_results || format('A5 FAIL: auto customer not archived correctly -- %s', v_row) || E'\n';
  end if;

  if exists (select 1 from audit_log where table_name='customers' and row_id=v_real_merge_target and action='customer_link_otp_merge' and after->>'reason'='otp_verified')
     and exists (select 1 from audit_log where table_name='customers' and row_id=v_auto_merge and action='customer_link_otp_merge_archived' and after->>'reason'='otp_verified') then
    v_results := v_results || 'A6 ok: both audit_log rows present with reason otp_verified' || E'\n';
  else
    v_results := v_results || 'A6 FAIL: audit_log rows missing or wrong' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario B: CLAIM OWN NUMBER -- caller has an empty auto customer, zero matches.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_claim, v_org, '__TEST_auto_claim', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_claim', 'customer_app', v_u_claim, 'claim@example.invalid')
  returning id into v_auto_claim;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_claim, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000102') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from customer_link_otp_challenges where customer_id = v_auto_claim and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from whatsapp_outbox where ref_type='customer_link_otp' and ref_id = v_challenge_id;
  if v_challenge_id is not null and v_code is not null then
    v_results := v_results || 'B1 ok: zero-match request for a relaxed caller still sends a code, challenge targets the CALLER''S OWN customer' || E'\n';
  else
    v_results := v_results || 'B1 FAIL: zero-match request for a relaxed caller did not send' || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_claim, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked') then
    v_results := v_results || 'B2 ok: claim-own-number verify succeeds' || E'\n';
  else
    v_results := v_results || format('B2 FAIL: %s', v_result) || E'\n';
  end if;

  select * into v_row from customers where id = v_auto_claim;
  if v_row.mobile = '9000000102' and v_row.phone_verified = true and v_row.archived_at is null and v_row.primary_profile_id = v_u_claim then
    v_results := v_results || 'B3 ok: caller''s OWN customer now has the verified mobile, no merge/archive happened' || E'\n';
  else
    v_results := v_results || format('B3 FAIL: %s', v_row) || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario C: AMBIGUOUS (2+ matches) -- no link, caller's own auto customer flagged needs_review,
  -- generic response unchanged.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_ambiguous, v_org, '__TEST_auto_ambiguous', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_ambiguous', 'customer_app', v_u_ambiguous, 'ambiguous@example.invalid')
  returning id into v_auto_ambiguous;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_amb_1', '9000000103') returning id into v_real_amb_1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_amb_2', '9000000103') returning id into v_real_amb_2;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_ambiguous, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000103') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.') then
    v_results := v_results || 'C1 ok: ambiguous match still returns the generic response (no oracle)' || E'\n';
  else
    v_results := v_results || format('C1 FAIL: %s', v_result) || E'\n';
  end if;

  if not exists (select 1 from customer_link_otp_challenges where customer_id in (v_real_amb_1, v_real_amb_2, v_auto_ambiguous) and used_at is null and superseded_at is null) then
    v_results := v_results || 'C2 ok: ambiguous match sends no code at all' || E'\n';
  else
    v_results := v_results || 'C2 FAIL: a challenge was created despite the ambiguous match' || E'\n';
  end if;

  select needs_review, needs_review_reason into v_row from customers where id = v_auto_ambiguous;
  if (select needs_review from customers where id = v_auto_ambiguous) = true
     and (select needs_review_reason from customers where id = v_auto_ambiguous) = 'phone matched more than one existing customer' then
    v_results := v_results || 'C3 ok: caller''s own auto customer flagged needs_review with the right reason' || E'\n';
  else
    v_results := v_results || 'C3 FAIL: needs_review not set correctly for the ambiguous case' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario D: already linked to a DIFFERENT sign-in -- no link, needs_review, generic response.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_linked_elsewhere, v_org, '__TEST_auto_linked_elsewhere', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_linked_elsewhere', 'customer_app', v_u_linked_elsewhere, 'elsewhere@example.invalid')
  returning id into v_auto_linked_elsewhere;
  insert into profiles (id, org_id, full_name, role) values (v_u_someone_else, v_org, '__TEST_someone_else', 'customer');
  insert into customers (org_id, name, mobile, primary_profile_id)
  select v_org, '__TEST_real_taken', '9000000104', id from profiles where full_name = '__TEST_someone_else'
  returning id into v_real_taken;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_linked_elsewhere, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000104') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.') then
    v_results := v_results || 'D1 ok: already-linked-elsewhere match returns the generic response' || E'\n';
  else
    v_results := v_results || format('D1 FAIL: %s', v_result) || E'\n';
  end if;

  if (select needs_review from customers where id = v_auto_linked_elsewhere) = true
     and (select needs_review_reason from customers where id = v_auto_linked_elsewhere) = 'phone already linked to a different sign-in' then
    v_results := v_results || 'D2 ok: caller''s own auto customer flagged needs_review for the already-linked-elsewhere case' || E'\n';
  else
    v_results := v_results || 'D2 FAIL: needs_review not set correctly' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario E: race loss on CLAIM OWN NUMBER -- another customer claims the exact number between
  -- request and verify.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_claim_race, v_org, '__TEST_auto_claim_race', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_claim_race', 'customer_app', v_u_claim_race, 'claimrace@example.invalid')
  returning id into v_auto_claim_race;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_claim_race, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000105') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from customer_link_otp_challenges where customer_id = v_auto_claim_race and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from whatsapp_outbox where ref_type='customer_link_otp' and ref_id = v_challenge_id;

  -- Simulate a DIFFERENT real customer claiming the exact same number in the meantime.
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_racer', '9000000105') returning id into v_racer_customer;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_claim_race, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0) then
    v_results := v_results || 'E1 ok: claim-own-number race loss returns the same collapsed response as every other race loss' || E'\n';
  else
    v_results := v_results || format('E1 FAIL: %s', v_result) || E'\n';
  end if;

  if (select mobile from customers where id = v_auto_claim_race) is null then
    v_results := v_results || 'E2 ok: caller''s own customer did NOT get the mobile set after losing the race' || E'\n';
  else
    v_results := v_results || 'E2 FAIL: mobile was set despite the race loss' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario F: race loss on MERGE -- real activity lands on the caller's auto customer between
  -- request and verify (so it is no longer "empty").
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_merge_race, v_org, '__TEST_auto_merge_race', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_merge_race', 'customer_app', v_u_merge_race, 'mergerace@example.invalid')
  returning id into v_auto_merge_race;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_real_merge_race_target', '9000000106') returning id into v_real_merge_race_target;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_merge_race, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000106') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from customer_link_otp_challenges where customer_id = v_real_merge_race_target and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from whatsapp_outbox where ref_type='customer_link_otp' and ref_id = v_challenge_id;

  -- Simulate real activity landing on the caller's own auto customer in the meantime (a ticket).
  insert into service_tickets (org_id, customer_id, status) values (v_org, v_auto_merge_race, 'open');

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_merge_race, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0) then
    v_results := v_results || 'F1 ok: merge race loss (real activity landed on FROM) returns the same collapsed response' || E'\n';
  else
    v_results := v_results || format('F1 FAIL: %s', v_result) || E'\n';
  end if;

  if (select primary_profile_id from customers where id = v_real_merge_race_target) is null
     and (select archived_at from customers where id = v_auto_merge_race) is null then
    v_results := v_results || 'F2 ok: neither customer was touched after the race loss' || E'\n';
  else
    v_results := v_results || 'F2 FAIL: a customer was modified despite the race loss' || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario G: UNCHANGED -- a caller with NO profile at all still behaves exactly as before
  -- this migration (the original path).
  ----------------------------------------------------------------------------
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_no_profile_target', '9000000107') returning id into v_no_profile_target;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_no_profile, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.request_customer_link_code('9000000107') into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  select id into v_challenge_id from customer_link_otp_challenges where customer_id = v_no_profile_target and used_at is null and superseded_at is null;
  select payload->>'code' into v_code from whatsapp_outbox where ref_type='customer_link_otp' and ref_id = v_challenge_id;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_no_profile, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.verify_customer_link_code(v_code) into v_result;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  if v_result = jsonb_build_object('status', 'linked')
     and (select primary_profile_id from customers where id = v_no_profile_target) = v_u_no_profile
     and exists (select 1 from profiles where id = v_u_no_profile) then
    v_results := v_results || 'G1 ok: the ORIGINAL no-profile-at-all path still works completely unchanged' || E'\n';
  else
    v_results := v_results || format('G1 FAIL: %s', v_result) || E'\n';
  end if;

  ----------------------------------------------------------------------------
  -- Scenario H: an auto customer that already has real records (NOT empty) still gets the
  -- original profile_exists refusal, unaffected by this migration.
  ----------------------------------------------------------------------------
  insert into profiles (id, org_id, full_name, role) values (v_u_has_records, v_org, '__TEST_auto_has_records', 'customer');
  insert into customers (org_id, name, source, primary_profile_id, email)
  values (v_org, '__TEST_auto_has_records', 'customer_app', v_u_has_records, 'hasrecords@example.invalid')
  returning id into v_auto_has_records;
  insert into service_tickets (org_id, customer_id, status) values (v_org, v_auto_has_records, 'open');

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_has_records, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform public.request_customer_link_code('9000000108');
    v_results := v_results || 'H1 FAIL: a non-empty auto customer was let through -- should have raised profile_exists' || E'\n';
  exception when others then
    v_results := v_results || 'H1 ok: a non-empty auto customer still gets profile_exists (' || sqlerrm || ')' || E'\n';
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);

  ----------------------------------------------------------------------------
  -- Scenario I: customer_link_otp_card_eligible() -- the frontend card's own eligibility check.
  ----------------------------------------------------------------------------
  perform set_config('request.jwt.claims', json_build_object('sub', v_u_claim, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.customer_link_otp_card_eligible() into v_eligible;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);
  if v_eligible is false then
    -- v_u_claim already claimed their own number in scenario B -- no longer eligible (the card's
    -- job is to offer linking ONCE; after a successful claim/merge the customer is no longer the
    -- empty auto shape -- mobile is now set).
    v_results := v_results || 'I1 ok: a customer who already claimed their number is no longer eligible' || E'\n';
  else
    v_results := v_results || format('I1 FAIL: expected false, got %s', v_eligible) || E'\n';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_u_has_records, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select public.customer_link_otp_card_eligible() into v_eligible;
  execute 'reset role';
  perform set_config('request.jwt.claims', 'null', true);
  if v_eligible is false then
    v_results := v_results || 'I2 ok: a non-empty auto customer is not eligible' || E'\n';
  else
    v_results := v_results || format('I2 FAIL: expected false, got %s', v_eligible) || E'\n';
  end if;

  select public.customer_link_otp_card_eligible() into v_eligible;
  if v_eligible is false then
    -- Unauthenticated (no request.jwt.claims set at all right now) -- must be false, never raise.
    v_results := v_results || 'I3 ok: an unauthenticated caller gets false, not an error' || E'\n';
  else
    v_results := v_results || 'I3 FAIL' || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$t$;
