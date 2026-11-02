-- Test for 20261121100100_customer_link_otp_dispatch_hardening.sql.
-- Run inside the rehearsal wrapper's own transaction, AFTER the migration has been applied in the
-- same transaction (never standalone against real data). Ends by raising an exception listing
-- every assertion's pass/fail so the wrapper's own outer RAISE EXCEPTION captures it, and so
-- nothing here ever commits regardless of outcome.
do $test$
declare
  v_results text := '';
  v_org_id uuid;
  v_customer_expired uuid;
  v_customer_valid uuid;
  v_customer_used uuid;
  v_outbox_expired uuid;
  v_outbox_valid uuid;
  v_outbox_used uuid;
  v_scrubbed int;
  v_row record;
begin
  -- Use a throwaway __TEST_ org, never a real one. Three separate customers, one per scenario --
  -- customer_link_otp_challenges_one_active_idx allows only one "active" (used_at and
  -- superseded_at both null) challenge PER CUSTOMER, and the expired/valid scenarios below are
  -- both "active" by that definition (only used_at being set makes P3's row inactive).
  insert into public.organizations (name) values ('__TEST_dispatch_hardening') returning id into v_org_id;

  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_expired', '9000000991')
  returning id into v_customer_expired;
  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_valid', '9000000992')
  returning id into v_customer_valid;
  insert into public.customers (org_id, name, mobile) values (v_org_id, '__TEST_customer_dh_used', '9000000993')
  returning id into v_customer_used;

  -- G0: prerequisite objects exist.
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    v_results := v_results || 'G0 FAIL: scrub_expired_customer_link_otp_outbox missing' || E'\n';
  else
    v_results := v_results || 'G0 ok: scrub_expired_customer_link_otp_outbox exists' || E'\n';
  end if;

  if not exists (select 1 from cron.job where jobname = 'customer-link-otp-expiry-scrub') then
    v_results := v_results || 'G1 FAIL: cron job not scheduled' || E'\n';
  else
    v_results := v_results || 'G1 ok: cron job scheduled' || E'\n';
  end if;

  if has_function_privilege('anon', 'public.scrub_expired_customer_link_otp_outbox()', 'execute')
     or has_function_privilege('authenticated', 'public.scrub_expired_customer_link_otp_outbox()', 'execute') then
    v_results := v_results || 'G2 FAIL: scrub function is anon/authenticated-executable' || E'\n';
  else
    v_results := v_results || 'G2 ok: scrub function not anon/authenticated-executable' || E'\n';
  end if;

  -- P1: an EXPIRED, never-sent, still-pending row is scrubbed. Carries a wasi_response too, even
  -- though a never-sent row wouldn't realistically have one -- exercises the second-review-round
  -- fix (scrub_whatsapp_outbox_wasi_response) on the same update regardless.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, wasi_response, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000991', v_customer_expired, 'customer_link_otp', '__TEST__otp', '{"body":"482913 is your code","code":"482913"}'::jsonb, '{"code":"482913"}'::jsonb, '{"echoed_params":{"1":"482913"}}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_expired;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_expired, 'salt', 'hash', clock_timestamp() - interval '1 minute', v_outbox_expired);

  -- P2: a still-VALID pending row must be left completely untouched.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000992', v_customer_valid, 'customer_link_otp', '__TEST__otp', '{"body":"111222 is your code","code":"111222"}'::jsonb, '{"code":"111222"}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_valid;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_valid, 'salt', 'hash', clock_timestamp() + interval '5 minutes', v_outbox_valid);

  -- P3: a USED-but-somehow-still-pending row (defense in depth) is also scrubbed.
  insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, ref_type, ref_id, status)
  values (gen_random_uuid(), v_org_id, 'outbound', '9000000993', v_customer_used, 'customer_link_otp', '__TEST__otp', '{"body":"999888 is your code","code":"999888"}'::jsonb, '{"code":"999888"}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
  returning id into v_outbox_used;
  insert into public.customer_link_otp_challenges (id, org_id, user_id, customer_id, code_salt, code_hash, expires_at, used_at, outbox_id)
  values (gen_random_uuid(), v_org_id, gen_random_uuid(), v_customer_used, 'salt', 'hash', clock_timestamp() + interval '5 minutes', clock_timestamp(), v_outbox_used);

  v_scrubbed := public.scrub_expired_customer_link_otp_outbox();
  if v_scrubbed <> 2 then
    v_results := v_results || format('P1-3 FAIL: expected 2 rows scrubbed, got %s', v_scrubbed) || E'\n';
  else
    v_results := v_results || 'P1-3 ok: exactly 2 rows scrubbed (expired + used-pending)' || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_expired;
  if v_row.status = 'failed' and v_row.error = 'otp_expired_or_used_db_sweep'
     and v_row.template_params is null and not (v_row.payload ? 'code')
     and v_row.payload->>'body' = '[redacted after otp expired/used]'
     and v_row.wasi_response is null then
    v_results := v_results || 'P1 ok: expired row scrubbed correctly (status/error/payload/template_params/wasi_response)' || E'\n';
  else
    v_results := v_results || format('P1 FAIL: expired row state wrong -- %s', v_row) || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_valid;
  if v_row.status = 'pending' and v_row.payload->>'code' = '111222' and v_row.template_params->>'code' = '111222' then
    v_results := v_results || 'P2 ok: still-valid pending row left completely untouched' || E'\n';
  else
    v_results := v_results || format('P2 FAIL: valid pending row was modified -- %s', v_row) || E'\n';
  end if;

  select * into v_row from public.whatsapp_outbox where id = v_outbox_used;
  if v_row.status = 'failed' and v_row.error = 'otp_expired_or_used_db_sweep' and v_row.template_params is null then
    v_results := v_results || 'P3 ok: used-but-pending row scrubbed correctly' || E'\n';
  else
    v_results := v_results || format('P3 FAIL: used-pending row state wrong -- %s', v_row) || E'\n';
  end if;

  -- P4: idempotent second call -- nothing left to scrub, no error, returns 0.
  v_scrubbed := public.scrub_expired_customer_link_otp_outbox();
  if v_scrubbed = 0 then
    v_results := v_results || 'P4 ok: second call is a no-op (0 rows)' || E'\n';
  else
    v_results := v_results || format('P4 FAIL: second call scrubbed %s rows, expected 0', v_scrubbed) || E'\n';
  end if;

  -- P5: second independent-review finding -- the REAL send path (wa-send-core.ts's
  -- patchForOutcome update) never explicitly sets wasi_response to null itself; it relies entirely
  -- on scrub_whatsapp_outbox_wasi_response firing as a side effect of the status transition it
  -- DOES make (pending -> sent). Reproduce that exact shape here -- an UPDATE that only sets
  -- `status` (and unrelated columns), never mentioning wasi_response -- and confirm the trigger
  -- still nulls it, proving this isn't just a code-reading claim.
  declare
    v_outbox_sent uuid;
    v_sent_row record;
  begin
    insert into public.whatsapp_outbox (id, org_id, direction, to_mobile, customer_id, milestone, template, payload, template_params, wasi_response, ref_type, ref_id, status)
    values (gen_random_uuid(), v_org_id, 'outbound', '9000000994', v_customer_valid, 'customer_link_otp', '__TEST__otp', '{"body":"555666 is your code","code":"555666"}'::jsonb, '{"1":"555666"}'::jsonb, '{"meta_message_id":"wamid.fake","echoed_params":{"1":"555666"}}'::jsonb, 'customer_link_otp', gen_random_uuid(), 'pending')
    returning id into v_outbox_sent;

    -- Deliberately mirrors patchForOutcome's "sent" patch shape (wa-send-core.ts) -- status and a
    -- few unrelated columns, NEVER wasi_response or template_params.
    update public.whatsapp_outbox set status = 'sent', wa_message_id = 'wamid.fake', delivery_status = 'sent', error = null where id = v_outbox_sent;

    select * into v_sent_row from public.whatsapp_outbox where id = v_outbox_sent;
    if v_sent_row.template_params is null and v_sent_row.wasi_response is null and not (v_sent_row.payload ? 'code') then
      v_results := v_results || 'P5 ok: a real send-shaped update (status only) still triggers wasi_response AND template_params clearing' || E'\n';
    else
      v_results := v_results || format('P5 FAIL: send-shaped update did not clear everything -- %s', v_sent_row) || E'\n';
    end if;
  end;

  -- G3: registry note was refreshed and still marks customer_link_otp covered.
  if exists (
    select 1 from public.whatsapp_payload_secret_ref_types
    where ref_type = 'customer_link_otp' and redaction_covered = true
      and covered_note like '%scrub_expired_customer_link_otp_outbox%'
  ) then
    v_results := v_results || 'G3 ok: registry note refreshed and still covered=true' || E'\n';
  else
    v_results := v_results || 'G3 FAIL: registry row missing, not covered, or note not refreshed' || E'\n';
  end if;

  -- G4: the HIGH fix found by this phase's independent review -- service_role must be able to
  -- execute is_customer_link_otp_enabled(), or the Edge Function dispatcher's dispatch-time
  -- re-check (wa-milestone-dispatch-core.ts) silently fails open on EVERY call in production.
  if has_function_privilege('service_role', 'public.is_customer_link_otp_enabled()', 'execute') then
    v_results := v_results || 'G4 ok: service_role can execute is_customer_link_otp_enabled()' || E'\n';
  else
    v_results := v_results || 'G4 FAIL: service_role still cannot execute is_customer_link_otp_enabled()' || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$test$;
