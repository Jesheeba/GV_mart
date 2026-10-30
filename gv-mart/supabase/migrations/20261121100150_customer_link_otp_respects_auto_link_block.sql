-- 20261121100150_customer_link_otp_respects_auto_link_block.sql
--
-- Phase 3 continuation, docs/DECISIONS.md section 12/13. Closes the BLOCKING QUESTION raised and
-- reported (not silently fixed) in section 12.3: `verify_customer_link_code` (phone-based OTP
-- link, this feature) did not respect `customers.auto_link_blocked_at` the way
-- `customer_auto_onboard()` (email-based auto-link, 20261130100001, already live) already does --
-- a customer a master unlinked via `admin_unlink_customer_google_account` (20261121100000,
-- already live, redefined by 20261130100002 to set this column, already live) could be silently
-- re-linked to a DIFFERENT Google sign-in through the phone/OTP path, defeating the master's
-- unlink exactly the way the "unlink loop" 20261130100002 closed for the email path. Owner
-- APPROVED this exact guard before it was written (the proposal in section 12.3).
--
-- Ordering: strictly AFTER 20261121100100 (dispatch hardening + wasi_response trigger -- this
-- migration does not depend on it directly, but the owner's own ordering instruction keeps the
-- redaction/re-check work before this) and strictly BEFORE 20261121100200 (the template mapping,
-- unaffected by anything here) -- `100150` sorts between `100100` and `100200`.
--
-- NEVER editing the already-applied 20261120100000_customer_link_otp.sql: both functions below
-- are `create or replace`, reproducing the LIVE bodies verbatim (confirmed via
-- `pg_get_functiondef`, sha256-pinned below, CR-tolerant -- this migration REFUSES to apply if the
-- live definition has drifted from what was read when this file was written, exactly the same
-- discipline `20261130100002` used for the two admin link functions) plus exactly ONE added
-- condition each:
--   - `request_customer_link_code`: the match-exclusion condition
--     (`v_match_count <> 1 or v_match_primary_profile_id is not null or v_match_is_test`) gains
--     `or v_match_auto_link_blocked_at is not null` -- a blocked customer becomes indistinguishable
--     from an already-linked/test one, same generic `v_generic` response, same `'no_match'`
--     send-log decision, so the response shape (and the send-log row it creates) leaks nothing new
--     about the phone number typed -- no new oracle, exactly the owner's own explicit requirement.
--   - `verify_customer_link_code`: the lock-time re-check immediately before linking
--     (`primary_profile_id is not null or is_test`) gains `or auto_link_blocked_at is not null` --
--     same collapsed `{status: 'invalid_or_expired', attempts_left: 0}` response as every other
--     "lost the race" case already returns, so a caller holding a correct, not-yet-expired code
--     for a customer who gets blocked in between request and verify sees the IDENTICAL response
--     shape and timing profile as any other race loss, not a new, distinguishable outcome.
-- Nothing else in either function changes: not the rate limits, not the timing-equalization dummy
-- crypto work on the no-match branch (section 7), not the attempts/expiry logic, not the audit_log
-- writes (which still never include the code or the block reason -- confirmed, unchanged).
--
-- Grants and search_path are UNCHANGED from the live functions (confirmed by this migration's own
-- assertions below, not assumed from `create or replace` alone -- Postgres does carry grants
-- across a `create or replace function`, but this migration still re-states and re-verifies them
-- explicitly, same discipline as every other grant-sensitive migration on this branch): `anon` has
-- no EXECUTE, `authenticated` has EXECUTE, `set search_path = public, extensions, pg_temp` for
-- both.

do $mig$
declare
  v_expected_request_hash text := '9e108f6e9f55ad8539773de90d3ceca201231e24874854d3db855f41829557a3';
  v_expected_verify_hash  text := '2a12b2ef965e068297a40922f88477b9b8db92196b896755bc4599196e374bb4';
  v_actual_request_hash text;
  v_actual_verify_hash  text;
begin
  if to_regprocedure('public.request_customer_link_code(text)') is null
     or to_regprocedure('public.verify_customer_link_code(text)') is null then
    raise exception 'customer_link_otp_respects_auto_link_block: base functions missing -- 20261120100000 not applied';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'auto_link_blocked_at') then
    raise exception 'customer_link_otp_respects_auto_link_block: customers.auto_link_blocked_at missing -- 20261130100000 not applied';
  end if;

  -- LIVE-DRIFT CHECK: refuse to replace either function unless its CURRENT live body still
  -- matches the exact body this migration was written against (CR-tolerant, same as every other
  -- sha256 pin on this branch). A real difference here means someone else changed either function
  -- since this migration was written -- this migration must not silently clobber that change.
  v_actual_request_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.request_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_request_hash is distinct from v_expected_request_hash then
    raise exception 'customer_link_otp_respects_auto_link_block: LIVE_DEFINITION_DRIFT -- request_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_request_hash, v_actual_request_hash;
  end if;

  v_actual_verify_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.verify_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_verify_hash is distinct from v_expected_verify_hash then
    raise exception 'customer_link_otp_respects_auto_link_block: LIVE_DEFINITION_DRIFT -- verify_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_verify_hash, v_actual_verify_hash;
  end if;

  -- ── request_customer_link_code: add v_match_auto_link_blocked_at, select it, check it ───────
  create or replace function public.request_customer_link_code(p_mobile text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, extensions, pg_temp
  as $fn$
  declare
    v_user_id uuid := auth.uid();
    v_generic jsonb := jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.');
    v_phone_hash text;
    v_phone_last4 text;
    v_match_id uuid;
    v_match_org_id uuid;
    v_match_primary_profile_id uuid;
    v_match_is_test boolean;
    v_match_auto_link_blocked_at timestamptz;
    v_match_preferred_language text;
    v_match_count integer;
    v_now timestamptz := clock_timestamp();
    v_user_sends_last_hour integer;
    v_phone_sends_last_hour integer;
    v_last_send_at timestamptz;
    v_distinct_numbers_24h integer;
    v_code text;
    v_salt text;
    v_challenge_id uuid;
    v_outbox_id uuid;
    v_body text;
  begin
    if v_user_id is null then
      raise exception 'cannot_request_code: not authenticated';
    end if;

    if exists (select 1 from public.profiles where id = v_user_id) then
      raise exception 'cannot_request_code: profile_exists';
    end if;

    if p_mobile !~ '^[6-9]\d{9}$' then
      raise exception 'cannot_request_code: invalid_mobile';
    end if;

    if not public.is_customer_link_otp_enabled() then
      raise exception 'cannot_request_code: feature_disabled';
    end if;

    v_phone_hash := encode(digest(p_mobile, 'sha256'), 'hex');
    v_phone_last4 := right(p_mobile, 4);

    select count(*) into v_user_sends_last_hour
    from public.customer_link_otp_send_log
    where user_id = v_user_id and created_at > v_now - interval '1 hour';

    select count(*) into v_phone_sends_last_hour
    from public.customer_link_otp_send_log
    where phone_hash = v_phone_hash and created_at > v_now - interval '1 hour';

    select max(created_at) into v_last_send_at
    from public.customer_link_otp_send_log
    where user_id = v_user_id and decision = 'sent';

    select count(distinct phone_hash) into v_distinct_numbers_24h
    from public.customer_link_otp_send_log
    where user_id = v_user_id and created_at > v_now - interval '24 hours';

    if v_last_send_at is not null and v_last_send_at > v_now - interval '30 seconds' then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_cooldown');
      return v_generic;
    end if;

    if v_user_sends_last_hour >= 5 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_user');
      return v_generic;
    end if;

    if v_phone_sends_last_hour >= 3 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_phone');
      return v_generic;
    end if;

    if v_distinct_numbers_24h >= 5 then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'limited_distinct_numbers');
      return v_generic;
    end if;

    select count(*) into v_match_count from public.customers where mobile = p_mobile;

    if v_match_count = 1 then
      select id, org_id, primary_profile_id, is_test, auto_link_blocked_at, preferred_language
      into v_match_id, v_match_org_id, v_match_primary_profile_id, v_match_is_test, v_match_auto_link_blocked_at, v_match_preferred_language
      from public.customers where mobile = p_mobile;
    end if;

    -- ADDED (this migration, owner-approved guard): a customer a master unlinked via
    -- admin_unlink_customer_google_account (auto_link_blocked_at set) is treated identically to
    -- an already-linked or test customer -- same v_generic response, same 'no_match' decision row
    -- in the send log -- so this response is indistinguishable from a non-matching phone number,
    -- exactly as the owner required (no new oracle).
    if v_match_count <> 1
       or v_match_primary_profile_id is not null
       or v_match_is_test
       or v_match_auto_link_blocked_at is not null then
      perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end if;

    perform pg_advisory_xact_lock(hashtext(v_match_id::text));

    update public.customer_link_otp_challenges
    set superseded_at = v_now
    where customer_id = v_match_id and used_at is null and superseded_at is null;

    v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
    v_salt := encode(gen_random_bytes(16), 'hex');

    begin
      insert into public.customer_link_otp_challenges (org_id, user_id, customer_id, code_salt, code_hash, expires_at)
      values (v_match_org_id, v_user_id, v_match_id, v_salt, encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_now + interval '10 minutes')
      returning id into v_challenge_id;
    exception when unique_violation then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end;

    v_body := case coalesce(v_match_preferred_language, 'en')
      when 'ta' then v_code || ' உங்கள் GV Mart கணக்கு இணைப்பு குறியீடு. இதை யாருடனும் பகிர வேண்டாம். 10 நிமிடங்களில் காலாவதியாகும்.'
      else v_code || ' is your GV Mart account linking code. Do not share it with anyone. It expires in 10 minutes.'
    end;

    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (v_match_org_id, 'outbound', p_mobile, v_match_id, 'customer_link_otp', 'customer_link_otp',
            jsonb_build_object('body', v_body, 'code', v_code), 'customer_link_otp', v_challenge_id, 'pending')
    returning id into v_outbox_id;

    update public.customer_link_otp_challenges set outbox_id = v_outbox_id where id = v_challenge_id;

    insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
    values (v_user_id, v_phone_hash, v_phone_last4, 'sent');

    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (v_match_org_id, null, 'customer_link_otp_requested', 'customers', v_match_id,
            jsonb_build_object('auth_user_id', v_user_id, 'phone_last4', v_phone_last4, 'challenge_id', v_challenge_id));

    begin
      perform public.wa_otp_fast_dispatch_invoke(v_match_org_id);
    exception when others then
      null;
    end;

    return v_generic;
  end;
  $fn$;

  revoke all on function public.request_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.request_customer_link_code(text) to authenticated;

  -- ── verify_customer_link_code: add auto_link_blocked_at to the lock-time re-check ───────────
  create or replace function public.verify_customer_link_code(p_code text)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, extensions, pg_temp
  as $fn$
  declare
    v_user_id uuid := auth.uid();
    v_challenge record;
    v_code_hash text;
    v_rows_updated integer;
    v_default_attempts_left constant integer := 5;
  begin
    if v_user_id is null then
      raise exception 'cannot_verify_code: not authenticated';
    end if;

    if exists (select 1 from public.profiles where id = v_user_id) then
      raise exception 'cannot_verify_code: profile_exists';
    end if;

    if p_code !~ '^\d{6}$' then
      raise exception 'cannot_verify_code: invalid_format';
    end if;

    if not public.is_customer_link_otp_enabled() then
      raise exception 'cannot_verify_code: feature_disabled';
    end if;

    select * into v_challenge
    from public.customer_link_otp_challenges
    where user_id = v_user_id and used_at is null and superseded_at is null
    order by created_at desc
    limit 1
    for update;

    if v_challenge.id is null then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', v_default_attempts_left);
    end if;

    if v_challenge.expires_at < clock_timestamp() then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', v_default_attempts_left);
    end if;

    if v_challenge.attempts >= v_challenge.max_attempts then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
    end if;

    v_code_hash := encode(digest(v_challenge.code_salt || p_code, 'sha256'), 'hex');

    if v_code_hash <> v_challenge.code_hash then
      update public.customer_link_otp_challenges
      set attempts = attempts + 1
      where id = v_challenge.id
      returning attempts into v_challenge.attempts;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
      values (v_challenge.org_id, null, 'customer_link_otp_wrong_code', 'customers', v_challenge.customer_id,
              jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id, 'attempts', v_challenge.attempts));

      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', greatest(v_challenge.max_attempts - v_challenge.attempts, 0));
    end if;

    update public.customer_link_otp_challenges set used_at = clock_timestamp() where id = v_challenge.id;

    perform 1 from public.customers where id = v_challenge.customer_id for update;

    -- ADDED (this migration, owner-approved guard): a customer blocked by a master's unlink
    -- between this challenge's request and this verify call is treated exactly like "lost the
    -- race" -- the IDENTICAL {status: 'invalid_or_expired', attempts_left: 0} response any other
    -- re-check failure already returns here, so there is no new, distinguishable outcome and no
    -- new timing signal (same code path, same statements run, whether blocked or already-linked
    -- or flagged test).
    if exists (
      select 1 from public.customers
      where id = v_challenge.customer_id and (primary_profile_id is not null or is_test or auto_link_blocked_at is not null)
    ) then
      return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
    end if;

    insert into public.profiles (id, org_id, full_name, phone, role, language)
    select v_user_id, c.org_id, coalesce(nullif(c.name, ''), 'Customer'), c.mobile, 'customer', coalesce(c.preferred_language, 'en')
    from public.customers c where c.id = v_challenge.customer_id;

    update public.customers
    set primary_profile_id = v_user_id, phone_verified = true
    where id = v_challenge.customer_id and primary_profile_id is null and not is_test;

    get diagnostics v_rows_updated = row_count;
    if v_rows_updated <> 1 then
      raise exception 'cannot_verify_code: unexpected_link_failure';
    end if;

    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (v_challenge.org_id, v_user_id, 'customer_link_otp_verified', 'customers', v_challenge.customer_id,
            jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id));

    return jsonb_build_object('status', 'linked');
  end;
  $fn$;

  revoke all on function public.verify_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.verify_customer_link_code(text) to authenticated;

  ----------------------------------------------------------------------------
  -- Assertions.
  ----------------------------------------------------------------------------
  if has_function_privilege('anon', 'public.request_customer_link_code(text)', 'execute')
     or has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'execute') then
    raise exception 'assertion failed: anon can execute request_customer_link_code or verify_customer_link_code';
  end if;

  if not (has_function_privilege('authenticated', 'public.request_customer_link_code(text)', 'execute')
          and has_function_privilege('authenticated', 'public.verify_customer_link_code(text)', 'execute')) then
    raise exception 'assertion failed: authenticated lost EXECUTE on request_customer_link_code or verify_customer_link_code';
  end if;

  if (select prosrc from pg_proc where oid = 'public.request_customer_link_code(text)'::regprocedure) not like '%v_match_auto_link_blocked_at%' then
    raise exception 'assertion failed: request_customer_link_code was not updated with the auto_link_blocked_at check';
  end if;

  if (select prosrc from pg_proc where oid = 'public.verify_customer_link_code(text)'::regprocedure) not like '%auto_link_blocked_at%' then
    raise exception 'assertion failed: verify_customer_link_code was not updated with the auto_link_blocked_at check';
  end if;
end
$mig$;
