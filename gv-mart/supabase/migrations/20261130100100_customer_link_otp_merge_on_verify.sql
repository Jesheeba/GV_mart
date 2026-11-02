-- 20261130100100_customer_link_otp_merge_on_verify.sql
--
-- WP1 (docs/DECISIONS.md section 15), owner-approved. Closes the gap found and reported read-only
-- in section 14.1: `request_customer_link_code`/`verify_customer_link_code` refuse outright
-- (`profile_exists`) for ANY caller who already has a `profiles` row -- which, since
-- `customer_auto_onboard()` went live (20261130100001), is now every Google sign-in. This
-- migration relaxes that refusal ONLY for a caller whose existing profile belongs to the empty,
-- auto-created ("app") customer `customer_auto_onboard` itself creates, reusing
-- `admin_merge_auto_customer`'s own exact safety preconditions (read live, not guessed) rather
-- than inventing new ones -- that function is NOT called directly (it requires `is_master()` and
-- `current_org_id()`; a bare customer calling these two RPCs is neither), its SAFETY LOGIC is.
--
-- Three outcomes from a successful code verification, per the owner's own product decision:
--   1. Exactly one existing, eligible (unlinked, not test, not blocked) OTHER customer matches the
--      phone -> MERGE: archive the caller's own empty auto customer (never delete), move the link
--      onto the matched customer, realign the profile, two audit_log rows, reason 'otp_verified'.
--   2. Zero existing customers match the phone -> CLAIM OWN NUMBER: no merge: set the caller's own
--      auto customer's `mobile`/`phone_verified` directly, but ONLY after re-confirming under lock,
--      at verify time, that no OTHER customer has claimed that exact number in the meantime (a
--      real race between request and verify, now that two different outcomes both write to
--      `customers.mobile`).
--   3. Two or more matches (ambiguous), or exactly one match that is already linked to a different
--      sign-in -> NO LINK, flag the caller's OWN auto customer `needs_review = true` (mirroring
--      `customer_auto_onboard`'s own ambiguous-email pattern -- the one real parallel already in
--      this codebase) so staff can resolve it by hand; the customer-visible response stays the
--      IDENTICAL generic shape every other non-send case already returns -- no oracle.
-- A match that is test-flagged or blocked (`auto_link_blocked_at is not null`) is unchanged: a
-- silent no-op, no flag, no send -- the owner's instructions name only "ambiguous" and "already
-- linked elsewhere" for the needs_review flag, not these two, so they are left exactly as before.
--
-- A caller with NO profile at all (the ORIGINAL, pre-auto-onboard case this feature was first
-- built for) is UNCHANGED in every respect, including a zero-match request: with no customer row
-- of their own to claim a number onto, that case still returns the generic no-send response
-- exactly as it always has -- the "claim own number" outcome only exists for the relaxed,
-- auto-customer caller shape.
--
-- NEVER editing the already-applied 20261120100000/20261121100150: both functions below are
-- `create or replace`, reproducing their LIVE bodies (as of this migration, after the
-- auto_link_blocked_at guard, 20261121100150, already applied) verbatim -- sha256-pinned via
-- `pg_get_functiondef`, CR-tolerant, refuses to apply on drift, same discipline as every prior
-- migration in this chain -- plus the additions described above, each marked "ADDED (this
-- migration)" in place, with every original comment preserved (the first draft of the
-- 20261121100150 guard dropped comments and had to be fixed after an independent review found it;
-- not repeating that mistake here).
--
-- Schema addition: `customer_link_otp_challenges.requested_mobile` (nullable text) -- the phone
-- number typed at request time, needed at verify time for the "claim own number" case's race
-- recheck (the challenge's own `customer_id` already points at a MATCHED customer in the merge
-- case, or at the CALLER'S OWN customer in the claim-own-number case -- there is no third place to
-- read the originally-typed number back from at verify time otherwise). Additive, nullable, zero
-- historical rows affected (`customer_link_otp_challenges` has zero rows live, confirmed read-only
-- before this migration was written).

do $mig$
declare
  v_expected_request_hash text := '755b065f63a159dc78cf253721f314ec77dc8792eba6b8e941f9102147dcb280';
  v_expected_verify_hash  text := '080ae7142651989723996d9e4ef387736e078097c9c9127818dd3eaa6cc015e2';
  v_actual_request_hash text;
  v_actual_verify_hash  text;
begin
  if to_regprocedure('public.request_customer_link_code(text)') is null
     or to_regprocedure('public.verify_customer_link_code(text)') is null then
    raise exception 'customer_link_otp_merge_on_verify: base functions missing';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='source') then
    raise exception 'customer_link_otp_merge_on_verify: customers.source missing -- 20261130100000 not applied';
  end if;

  -- LIVE-DRIFT CHECK, same discipline as 20261121100150.
  v_actual_request_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.request_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_request_hash is distinct from v_expected_request_hash then
    raise exception 'customer_link_otp_merge_on_verify: LIVE_DEFINITION_DRIFT -- request_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_request_hash, v_actual_request_hash;
  end if;
  v_actual_verify_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.verify_customer_link_code(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_actual_verify_hash is distinct from v_expected_verify_hash then
    raise exception 'customer_link_otp_merge_on_verify: LIVE_DEFINITION_DRIFT -- verify_customer_link_code''s live body no longer matches the pinned hash this migration was written against (expected %, got %)',
      v_expected_verify_hash, v_actual_verify_hash;
  end if;

  alter table public.customer_link_otp_challenges add column if not exists requested_mobile text;

  ----------------------------------------------------------------------------
  -- request_customer_link_code
  ----------------------------------------------------------------------------
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
    -- ADDED (this migration): the caller's own auto-created/empty customer, if the relaxed shape
    -- applies (null otherwise, including for a caller with no profile at all).
    v_caller_customer_id uuid;
    v_caller_org_id uuid;
    v_caller_preferred_language text;
    -- ADDED (this migration): whichever customer a sent code should ultimately resolve to at
    -- verify time -- a matched OTHER customer (merge case) or the caller's own customer (claim
    -- own number case).
    v_target_customer_id uuid;
    v_target_org_id uuid;
    v_target_preferred_language text;
  begin
    if v_user_id is null then
      raise exception 'cannot_request_code: not authenticated';
    end if;

    -- ADDED (this migration): relax the refusal ONLY for a caller whose existing profile belongs
    -- to the empty, auto-created ("app") customer customer_auto_onboard() creates -- same six-
    -- table emptiness check admin_merge_auto_customer already uses as its own live precondition,
    -- read from that function directly, not reinvented. A staff/technician profile, or a customer
    -- profile already linked/merged into a real record, or an auto customer that already has real
    -- activity, still gets the exact original refusal below -- unchanged.
    if exists (select 1 from public.profiles where id = v_user_id) then
      select c.id, c.org_id, c.preferred_language
        into v_caller_customer_id, v_caller_org_id, v_caller_preferred_language
        from public.customers c
       where c.primary_profile_id = v_user_id
         and c.source = 'customer_app'
         and c.archived_at is null
         and not exists (select 1 from public.service_tickets st where st.customer_id = c.id)
         and not exists (select 1 from public.amc_contracts ac where ac.customer_id = c.id)
         and not exists (select 1 from public.warranties w where w.customer_id = c.id)
         and not exists (select 1 from public.rental_contracts rc where rc.customer_id = c.id)
         and not exists (select 1 from public.quotations q where q.customer_id = c.id)
         and not exists (select 1 from public.invoices i where i.customer_id = c.id);

      if v_caller_customer_id is null then
        raise exception 'cannot_request_code: profile_exists';
      end if;
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

    -- ADDED (this migration, owner's explicit product decision): ambiguous (2+ matches) or
    -- already linked to a different sign-in (exactly one match, but taken) -- never link, flag
    -- the CALLER's own auto customer for staff review (mirrors customer_auto_onboard's own
    -- ambiguous-email pattern), same generic response as always, no oracle. A caller with no
    -- relaxed customer of their own (the original no-profile-at-all case) has nothing to flag --
    -- silently skips the update, same v_generic response either way.
    if v_match_count > 1 or (v_match_count = 1 and v_match_primary_profile_id is not null) then
      if v_caller_customer_id is not null then
        update public.customers
        set needs_review = true,
            needs_review_reason = case when v_match_count > 1
              then 'phone matched more than one existing customer'
              else 'phone already linked to a different sign-in' end
        where id = v_caller_customer_id;
      end if;
      perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end if;

    -- Unchanged: a single match that is test-flagged or blocked -- silent no-op, no flag, no send.
    if v_match_count = 1 and (v_match_is_test or v_match_auto_link_blocked_at is not null) then
      perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end if;

    if v_match_count = 1 then
      -- Exactly one eligible OTHER customer -- MERGE target (unchanged target resolution from
      -- before this migration, just renamed into the shared v_target_* variables below).
      v_target_customer_id := v_match_id;
      v_target_org_id := v_match_org_id;
      v_target_preferred_language := v_match_preferred_language;
    else
      -- v_match_count = 0 here (every other branch above already returned).
      if v_caller_customer_id is null then
        -- UNCHANGED (the original, pre-this-migration case): no existing profile at all, zero
        -- matches, nothing to claim a number onto -- same generic no-send response as always.
        perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
        insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
        values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
        return v_generic;
      end if;
      -- ADDED (this migration): zero matches, but the caller has a relaxed empty auto customer of
      -- their own -- CLAIM OWN NUMBER target. The actual uniqueness recheck happens again at
      -- verify time, under lock, against requested_mobile -- this is a real race window (time
      -- passes between request and verify), not assumed safe just because it was true here.
      v_target_customer_id := v_caller_customer_id;
      v_target_org_id := v_caller_org_id;
      v_target_preferred_language := v_caller_preferred_language;
    end if;

    perform pg_advisory_xact_lock(hashtext(v_target_customer_id::text));

    update public.customer_link_otp_challenges
    set superseded_at = v_now
    where customer_id = v_target_customer_id and used_at is null and superseded_at is null;

    v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
    v_salt := encode(gen_random_bytes(16), 'hex');

    begin
      -- ADDED (this migration): requested_mobile, read back at verify time for the claim-own-
      -- number case's race recheck (see this migration's own header comment).
      insert into public.customer_link_otp_challenges (org_id, user_id, customer_id, code_salt, code_hash, expires_at, requested_mobile)
      values (v_target_org_id, v_user_id, v_target_customer_id, v_salt, encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_now + interval '10 minutes', p_mobile)
      returning id into v_challenge_id;
    exception when unique_violation then
      insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
      values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
      return v_generic;
    end;

    v_body := case coalesce(v_target_preferred_language, 'en')
      when 'ta' then v_code || ' உங்கள் GV Mart கணக்கு இணைப்பு குறியீடு. இதை யாருடனும் பகிர வேண்டாம். 10 நிமிடங்களில் காலாவதியாகும்.'
      else v_code || ' is your GV Mart account linking code. Do not share it with anyone. It expires in 10 minutes.'
    end;

    -- CHANGE (a): 'code' alongside 'body' -- the dispatcher needs the raw code as a value, not just
    -- embedded in a rendered sentence, for a future named-parameter template send. Both keys are
    -- wiped together the moment this row is redacted (the existing redaction code replaces the
    -- WHOLE payload column, not a per-key merge -- see wa-milestone-dispatch-core.ts /
    -- wa-dispatch-v2.ts), so adding this key does not widen how long the plaintext code survives.
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (v_target_org_id, 'outbound', p_mobile, v_target_customer_id, 'customer_link_otp', 'customer_link_otp',
            jsonb_build_object('body', v_body, 'code', v_code), 'customer_link_otp', v_challenge_id, 'pending')
    returning id into v_outbox_id;

    update public.customer_link_otp_challenges set outbox_id = v_outbox_id where id = v_challenge_id;

    insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
    values (v_user_id, v_phone_hash, v_phone_last4, 'sent');

    insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
    values (v_target_org_id, null, 'customer_link_otp_requested', 'customers', v_target_customer_id,
            jsonb_build_object('auth_user_id', v_user_id, 'phone_last4', v_phone_last4, 'challenge_id', v_challenge_id));

    -- CHANGE (b): the fast-dispatch nudge. See wa_otp_fast_dispatch_invoke's own header comment for
    -- why this exists and why its failure is swallowed rather than surfaced or rolled back.
    begin
      perform public.wa_otp_fast_dispatch_invoke(v_target_org_id);
    exception when others then
      null;
    end;

    return v_generic;
  end;
  $fn$;

  revoke all on function public.request_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.request_customer_link_code(text) to authenticated;

  ----------------------------------------------------------------------------
  -- verify_customer_link_code
  ----------------------------------------------------------------------------
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
    -- ADDED (this migration): which of the three outcomes this verify call resolves to.
    v_caller_customer_id uuid;
    v_from record;
    v_to record;
  begin
    if v_user_id is null then
      raise exception 'cannot_verify_code: not authenticated';
    end if;

    -- ADDED (this migration): relax the refusal for a caller whose existing profile belongs to an
    -- auto-created ("app") customer of their own -- DELIBERATELY a LOOSER check here than
    -- request_customer_link_code's own gate: this one is a pure ROUTING decision ("does a branch
    -- below apply to this caller at all"), not a final emptiness/eligibility verdict. The
    -- emptiness/eligibility precondition is re-verified, under lock, inside the MERGE branch
    -- itself (below) -- and a failure there gracefully returns the same collapsed
    -- invalid_or_expired response every other race-loss case in this function already returns.
    -- Requiring full emptiness HERE, at the top, would instead turn a genuine race (real activity
    -- landing on this customer in the gap between request and verify -- the exact case this
    -- migration's own test proves) into an unhandled `profile_exists` exception instead of the
    -- graceful collapse the owner's own "no oracle, same generic response shape" requirement
    -- demands -- found by this migration's own local rehearsal, not assumed safe from reasoning
    -- about the code alone. A profile that matches NEITHER this loose shape nor "no customer row
    -- at all" (a staff/technician profile, or a profile already merged into a REAL customer by a
    -- prior successful run of this same flow, whose own primary_profile_id now points elsewhere)
    -- still gets the exact original refusal below, unchanged -- there is no lock-gated branch for
    -- either of those, so nothing downstream would ever collapse them gracefully anyway.
    if exists (select 1 from public.profiles where id = v_user_id) then
      select c.id into v_caller_customer_id
        from public.customers c
       where c.primary_profile_id = v_user_id
         and c.source = 'customer_app';

      if v_caller_customer_id is null then
        raise exception 'cannot_verify_code: profile_exists';
      end if;
    end if;

    if p_code !~ '^\d{6}$' then
      raise exception 'cannot_verify_code: invalid_format';
    end if;

    if not public.is_customer_link_otp_enabled() then
      raise exception 'cannot_verify_code: feature_disabled';
    end if;

    -- Row lock on the caller's own single active (not used, not superseded) challenge. Scoping by
    -- user_id here (not just "the most recent challenge anywhere") is what stops a second
    -- authenticated user from ever verifying against a challenge they did not request themselves,
    -- even if they correctly guess the code -- the challenge is bound to the requester's own
    -- auth.uid(), checked here, not just to a customer_id/mobile they could type. The lock also
    -- means a second, concurrent verify call for the SAME challenge blocks here until the first
    -- call's transaction commits or rolls back, so two parallel guesses can never both read the
    -- same `attempts` value and both be let through, and two parallel correct-code calls can never
    -- both pass the "still unlinked" check below.
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

    -- Correct code: re-check the customer is still unlinked and not flagged test (defends against a
    -- race where staff linked/flagged the customer by hand between request and verify) and mark the
    -- challenge used inside the same row-locked transaction, then run the actual link. Marking it
    -- used FIRST, before the link itself, means the code is burned (single-use) even on the rare
    -- path where the link below then fails its own race check -- a deliberate choice recorded in
    -- DECISIONS.md section 3 (the alternative, marking it used only after a successful link, would
    -- let one correct code be retried indefinitely across repeated race losses).
    update public.customer_link_otp_challenges set used_at = clock_timestamp() where id = v_challenge.id;

    -- ADDED (this migration): branch on which of the three outcomes applies. v_caller_customer_id
    -- is null for the ORIGINAL no-profile-at-all caller -- that path is completely unchanged
    -- below. Otherwise, the challenge's own customer_id tells us which of the remaining two cases
    -- this is: if it equals the caller's own customer, this is CLAIM OWN NUMBER (no merge); if it
    -- points at a different customer, this is MERGE.
    if v_caller_customer_id is not null and v_challenge.customer_id = v_caller_customer_id then
      -- CLAIM OWN NUMBER: no merge, no new profile -- set this same customer's own mobile and
      -- phone_verified, but only after re-confirming under lock that no OTHER customer has since
      -- claimed that exact number (a real race, not assumed safe from request time).
      perform 1 from public.customers where id = v_caller_customer_id for update;

      if exists (
        select 1 from public.customers
        where mobile = v_challenge.requested_mobile and id <> v_caller_customer_id
      ) then
        -- Lost the race: someone else claimed/was given that number in the meantime. Same
        -- collapsed response as every other race-loss case in this function.
        return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
      end if;

      update public.customers
      set mobile = v_challenge.requested_mobile, phone_verified = true
      where id = v_caller_customer_id;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
      values (v_challenge.org_id, v_user_id, 'customer_link_otp_claimed_own_number', 'customers', v_caller_customer_id,
              jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id, 'reason', 'otp_verified'));

      return jsonb_build_object('status', 'linked');

    elsif v_caller_customer_id is not null then
      -- MERGE: the challenge targets a DIFFERENT, matched customer. Lock both rows in a fixed
      -- order (by id) regardless of which is which, same deadlock-avoidance convention
      -- admin_merge_auto_customer already uses, then re-verify EVERY precondition under lock --
      -- not trusted from request time, exactly like admin_merge_auto_customer itself never trusts
      -- anything without re-reading it under lock first.
      if v_caller_customer_id < v_challenge.customer_id then
        perform 1 from public.customers where id = v_caller_customer_id for update;
        perform 1 from public.customers where id = v_challenge.customer_id for update;
      else
        perform 1 from public.customers where id = v_challenge.customer_id for update;
        perform 1 from public.customers where id = v_caller_customer_id for update;
      end if;

      select * into v_from from public.customers where id = v_caller_customer_id;
      select * into v_to from public.customers where id = v_challenge.customer_id;

      if v_from.source is distinct from 'customer_app'
         or v_from.archived_at is not null
         or v_from.primary_profile_id is distinct from v_user_id
         or exists (select 1 from public.service_tickets where customer_id = v_from.id)
         or exists (select 1 from public.amc_contracts where customer_id = v_from.id)
         or exists (select 1 from public.warranties where customer_id = v_from.id)
         or exists (select 1 from public.rental_contracts where customer_id = v_from.id)
         or exists (select 1 from public.quotations where customer_id = v_from.id)
         or exists (select 1 from public.invoices where customer_id = v_from.id)
         or v_to.is_test
         or v_to.archived_at is not null
         or v_to.primary_profile_id is not null
         or v_to.auto_link_blocked_at is not null
      then
        -- Lost the race on either side (real activity landed on the caller's own auto customer, or
        -- the matched customer got linked/blocked/archived/flagged test in the meantime): the code
        -- is still burned, nothing else changes -- same collapsed response as every other
        -- re-check failure in this function.
        return jsonb_build_object('status', 'invalid_or_expired', 'attempts_left', 0);
      end if;

      -- FROM must be cleared FIRST -- customers.primary_profile_id is UNIQUE, so setting TO's
      -- while FROM still holds the same value would violate that constraint, same reasoning
      -- admin_merge_auto_customer's own comment already records. Archive, never delete.
      update public.customers set primary_profile_id = null, archived_at = now(), archived_by = null where id = v_from.id;
      update public.customers set primary_profile_id = v_user_id, phone_verified = true, email = coalesce(v_to.email, v_from.email) where id = v_to.id;

      -- The profile's display fields were set from the auto-created (FROM) customer at creation
      -- time -- now that it represents TO, bring them into line, same effect
      -- admin_merge_auto_customer's own merge path already has.
      update public.profiles
        set org_id = v_to.org_id, full_name = coalesce(nullif(v_to.name, ''), 'Customer'), phone = v_to.mobile, language = coalesce(v_to.preferred_language, 'en')
        where id = v_user_id;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
      values (
        v_to.org_id, v_user_id, 'customer_link_otp_merge', 'customers', v_to.id,
        jsonb_build_object('primary_profile_id', null),
        jsonb_build_object('primary_profile_id', v_user_id, 'merged_from_customer_id', v_from.id, 'reason', 'otp_verified')
      );
      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
      values (
        v_from.org_id, v_user_id, 'customer_link_otp_merge_archived', 'customers', v_from.id,
        jsonb_build_object('primary_profile_id', v_user_id, 'archived_at', null),
        jsonb_build_object('primary_profile_id', null, 'archived_at', now(), 'merged_into_customer_id', v_to.id, 'reason', 'otp_verified')
      );

      return jsonb_build_object('status', 'linked');

    else
      -- UNCHANGED: the ORIGINAL no-profile-at-all path, exactly as it has always been.
      perform 1 from public.customers where id = v_challenge.customer_id for update;

      if exists (
        select 1 from public.customers
        where id = v_challenge.customer_id and (primary_profile_id is not null or is_test or auto_link_blocked_at is not null)
      ) then
        -- Lost the race (or the customer was flagged test / linked by hand / blocked by a master in
        -- between): the code is still burned (used_at was already set above), but no profile is
        -- created and nothing else changes.
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
        -- Cannot actually happen given the row lock + re-check immediately above (nothing else can
        -- change this row between here and there), but checked anyway rather than assumed.
        raise exception 'cannot_verify_code: unexpected_link_failure';
      end if;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
      values (v_challenge.org_id, v_user_id, 'customer_link_otp_verified', 'customers', v_challenge.customer_id,
              jsonb_build_object('auth_user_id', v_user_id, 'challenge_id', v_challenge.id));

      return jsonb_build_object('status', 'linked');
    end if;
  end;
  $fn$;

  revoke all on function public.verify_customer_link_code(text) from public, anon, authenticated;
  grant execute on function public.verify_customer_link_code(text) to authenticated;

  ----------------------------------------------------------------------------
  -- ADDED (this migration, WP2's own need): a read-only eligibility check the frontend's new
  -- home/profile card uses to decide whether to render at all. Deliberately a SEPARATE, narrow,
  -- read-only function rather than exposing `customers.source`/the six-table emptiness check (or
  -- any other raw column) to the client directly -- the exact same eligibility test
  -- `request_customer_link_code`'s own relaxation gate uses, single-sourced here so the two can
  -- never silently drift apart. Returns false (never raises) for a caller who is not
  -- authenticated, has no profile yet, or is not this exact shape -- the card is the ONLY thing
  -- that reads this; it carries no other information (not the customer's id, not why it's
  -- ineligible) that could leak anything about the caller's own account to itself (a non-issue in
  -- practice -- the caller already knows their own state -- but kept narrow regardless, same
  -- discipline as everything else in this feature).
  create or replace function public.customer_link_otp_card_eligible()
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, extensions, pg_temp
  as $fn$
  declare
    v_user_id uuid := auth.uid();
  begin
    if v_user_id is null then
      return false;
    end if;
    if not public.is_customer_link_otp_enabled() then
      return false;
    end if;
    return exists (
      select 1 from public.customers c
      where c.primary_profile_id = v_user_id
        and c.source = 'customer_app'
        and c.archived_at is null
        -- ADDED beyond the merge's own six-table test: once this customer already has a mobile
        -- number (set either by a prior claim-own-number or, moot for this row specifically since
        -- a merge's FROM side is archived, a prior merge), the card has done its job -- showing it
        -- again would invite a pointless repeat with no record left to merge or number left to
        -- claim. Scoped to this read-only eligibility check ONLY, not to request_customer_link_code's
        -- or verify_customer_link_code's own gates, which stay exactly the "same emptiness test as
        -- the merge" the owner specified, unchanged.
        and c.mobile is null
        and not exists (select 1 from public.service_tickets st where st.customer_id = c.id)
        and not exists (select 1 from public.amc_contracts ac where ac.customer_id = c.id)
        and not exists (select 1 from public.warranties w where w.customer_id = c.id)
        and not exists (select 1 from public.rental_contracts rc where rc.customer_id = c.id)
        and not exists (select 1 from public.quotations q where q.customer_id = c.id)
        and not exists (select 1 from public.invoices i where i.customer_id = c.id)
    );
  end;
  $fn$;

  revoke all on function public.customer_link_otp_card_eligible() from public, anon;
  grant execute on function public.customer_link_otp_card_eligible() to authenticated;

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
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customer_link_otp_challenges' and column_name='requested_mobile') then
    raise exception 'assertion failed: requested_mobile column was not created';
  end if;
  if (select prosrc from pg_proc where oid = 'public.request_customer_link_code(text)'::regprocedure) not like '%v_caller_customer_id%' then
    raise exception 'assertion failed: request_customer_link_code was not updated with the merge-on-verify relaxation';
  end if;
  if to_regprocedure('public.customer_link_otp_card_eligible()') is null then
    raise exception 'assertion failed: customer_link_otp_card_eligible was not created';
  end if;
  if has_function_privilege('anon', 'public.customer_link_otp_card_eligible()', 'execute') then
    raise exception 'assertion failed: anon can execute customer_link_otp_card_eligible';
  end if;
  if not has_function_privilege('authenticated', 'public.customer_link_otp_card_eligible()', 'execute') then
    raise exception 'assertion failed: authenticated cannot execute customer_link_otp_card_eligible';
  end if;
  if (select prosrc from pg_proc where oid = 'public.verify_customer_link_code(text)'::regprocedure) not like '%customer_link_otp_merge%' then
    raise exception 'assertion failed: verify_customer_link_code was not updated with the merge logic';
  end if;
end
$mig$;
