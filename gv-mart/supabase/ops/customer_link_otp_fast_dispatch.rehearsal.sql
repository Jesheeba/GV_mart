-- Rehearsal wrapper for supabase/migrations/20261120100100_customer_link_otp_fast_dispatch.sql + supabase/tests/customer_link_otp_fast_dispatch.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- except through the project's approved Management-API runner (supabase/ops/run_rehearsal.mjs,
-- sha256-verified before use), and only as a REHEARSAL: this block always ends in RAISE
-- EXCEPTION, so nothing it does can ever commit, regardless of pass/fail. Modeled on
-- customer_link_otp.rehearsal.sql's own convention (11:00 IST gate, org fingerprint pin,
-- sha256-pinned embedded text), adapted for a DELTA migration that redefines already-live
-- functions (create or replace) rather than creating brand-new ones.
--
-- This delta does NOT wire a whatsapp_event_templates mapping (the owner explicitly held that
-- pending a brand-neutrality confirmation of the 'lexdraft_otp' template) -- the rehearsal's own
-- post-checks assert no such row exists, so an accidental re-introduction of that insert would
-- fail the rehearsal, not just go unnoticed.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash text := 'a6bc5b6050841f5831ecc411c09c570abecb951dcec9f861f714788117eff4f0';
  v_expected_test_hash      text := 'ee9774e0ef309bbb2ffc359e1f001501a17ec4ca28cf253bf323024125a9abb2';
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before           text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_migration   text := $migration$-- Phase 2, Item 2 of the customer-OTP-link feature (docs/backlog-product-gaps.md): a fast
-- dispatch path for the customer_link_otp WhatsApp send, triggered immediately from inside
-- request_customer_link_code() via pg_net, because the GitHub Actions cron that would otherwise
-- pick the row up (wa-milestone-dispatch) fires every 3-7 HOURS in practice, not every 5 minutes
-- — hopeless against this challenge's own 10-minute expiry (DECISIONS.md section 2, the single
-- most load-bearing precondition in that document).
--
-- This is a SEPARATE, NEW migration, not an edit to 20261120100000_customer_link_otp.sql: that
-- file was already applied live (see docs/DECISIONS.md section 4b) and this project's standing
-- rule is that an applied migration file's bytes never change after the fact. Every statement
-- below is create-or-replace / create extension if not exists / revoke, i.e. safe against the
-- live project's current state regardless of how many times it runs.
--
-- EXPLICITLY NOT INCLUDED HERE, pending the owner's confirmation (2026-10-29): wiring
-- whatsapp_event_templates to the 'lexdraft_otp' template. The owner flagged that this template's
-- name suggests it may belong to a different product sharing this WhatsApp account and asked for
-- its exact body/category/language and a brand-neutrality check before anything maps this
-- feature to it. That mapping insert is held out of this migration entirely — see the final
-- report (DECISIONS.md section 9) for the template's details. Nothing in this migration makes
-- the feature capable of actually sending through any template; customer_link_otp_settings.enabled
-- still defaults to false and nothing here changes that.
--
-- pgcrypto note (same as the original migration): digest()/gen_random_bytes() live in the
-- `extensions` schema on this live project, so every function below that uses them sets
-- search_path = public, extensions, pg_temp.

-- ── 1. wa_otp_fast_dispatch_invoke ──────────────────────────────────────────────────────────
-- A 10-minute-expiry code cannot wait 3-7 hours for the cron. Precedent for triggering an Edge
-- Function from inside Postgres already exists in this codebase (branch feat/wa-cron-pgnet,
-- HELD pending an unrelated precondition, NOT merged/applied) — wa_cron_invoke(p_function) there
-- is an allow-listed, security-definer, vault-secret-gated net.http_post call. This follows the
-- same pattern but is a SEPARATE, narrower function with its own vault secret
-- (wa_otp_fast_dispatch_secret, distinct from that held branch's wa_cron_secret) and its own
-- target (a new, dedicated Edge Function, wa-otp-dispatch, not the general
-- wa-milestone-dispatch/wa-scheduled-tasks sweep) — deliberately NOT entangled with that held
-- branch, so this can ship independently of whatever it is still waiting on, and so a compromise
-- of either secret never grants the other.
--
-- Hardcoded to take only an org id — no function-name parameter like wa_cron_invoke's — because
-- this one has exactly one caller (request_customer_link_code, below) and exactly one purpose: it
-- must never become a general-purpose HTTP trigger. Operator step BEFORE the first real send (not
-- in this file, a secret must not be in git):
--   select vault.create_secret('<a fresh random value, NOT the same as CRON_SECRET>',
--                               'wa_otp_fast_dispatch_secret', 'Bearer token for wa-otp-dispatch');
-- and set the SAME value as the WA_OTP_FAST_DISPATCH_SECRET Edge Function secret. Until both are
-- set, the perform call in request_customer_link_code below raises inside its own exception
-- handler and is swallowed — a missing secret silently degrades this feature back to cron-only
-- latency rather than breaking the "code sent" response.
create extension if not exists pg_net with schema extensions;

create or replace function public.wa_otp_fast_dispatch_invoke(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault, net, pg_temp
as $$
declare
  v_secret text;
  v_id bigint;
begin
  if p_org_id is null then
    raise exception 'wa_otp_fast_dispatch_invoke: p_org_id is required';
  end if;

  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'wa_otp_fast_dispatch_secret'
  order by created_at desc
  limit 1;

  if v_secret is null or length(v_secret) = 0 then
    raise exception 'wa_otp_fast_dispatch_invoke: vault secret wa_otp_fast_dispatch_secret is missing';
  end if;

  -- Project URL hardcoded, same as the held wa_cron_invoke precedent — this project has exactly
  -- one Supabase project per environment and no config table a SECURITY DEFINER function should
  -- read for this instead.
  select net.http_post(
    url := 'https://fsunrjithwcjtsutsgea.supabase.co/functions/v1/wa-otp-dispatch',
    body := jsonb_build_object('org_id', p_org_id),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_secret, 'Content-Type', 'application/json'),
    timeout_milliseconds := 8000
  ) into v_id;
end;
$$;

-- This project auto-grants EXECUTE to anon/authenticated on every new public-schema function
-- (DECISIONS.md, "default-privileges anon EXECUTE leak") — this one reads a secret and triggers a
-- real outbound HTTP call, so it is closed explicitly, the same as wa_cron_invoke. Its only caller
-- is request_customer_link_code (SECURITY DEFINER calling another SECURITY DEFINER directly, a
-- plain PL/pgSQL function call — not a grant-mediated path), so nothing else needs EXECUTE on it.
revoke all on function public.wa_otp_fast_dispatch_invoke(uuid) from public, anon, authenticated;

-- ── 2. is_customer_link_otp_enabled — add the wa_dispatch_v2_scope precondition ─────────────
-- Independent-review finding (2026-10-29), MEDIUM: the live check required wa_dispatch_v2_enabled
-- = true but never checked wa_dispatch_v2_scope. That column defaults to 'numbers'
-- (20261016330000_wa_dispatch_v2_number_scope.sql), under which any to_mobile NOT on the
-- configured allow-list still falls through to the LEGACY dispatch loop
-- (runLegacyMilestoneDispatch in wa-milestone-dispatch-core.ts) — which has no atomic
-- claim-before-send (only a post-send `retried_at` stamp). Before this migration, that loop only
-- ran once per cron tick (every 3-7 hours in practice), so two customers racing the same org
-- inside one tick was rare. This migration's fast path (wa_otp_fast_dispatch_invoke, above) now
-- triggers a scan immediately on every successful OTP send, which makes two near-simultaneous
-- real link requests for the same org a realistic way to hit this non-atomic window and send ONE
-- customer_link_otp row's WhatsApp message twice. Fixed by also requiring
-- wa_dispatch_v2_scope = 'org' here, so this feature's flag can never read "on" while any
-- customer_link_otp row could still be routed through the legacy loop at all — not just the
-- plaintext-redaction precondition from the original migration, but this double-send
-- precondition too.
create or replace function public.is_customer_link_otp_enabled()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select
    coalesce((select enabled from public.customer_link_otp_settings where id = true), false)
    and exists (select 1 from public.settings where wa_dispatch_v2_enabled = true and wa_dispatch_v2_scope = 'org');
$$;

revoke all on function public.is_customer_link_otp_enabled() from public, anon;
grant execute on function public.is_customer_link_otp_enabled() to authenticated;

-- ── 3. request_customer_link_code — add the 'code' payload key + the fast-dispatch nudge ───
-- Full function body replayed verbatim from 20261120100000_customer_link_otp.sql with exactly
-- two changes, each marked below: (a) the whatsapp_outbox payload now also carries the raw code
-- under its own 'code' key, alongside the existing rendered 'body' sentence, so a future
-- template-based send can pass it as a named parameter without re-parsing the sentence; (b) a
-- best-effort nudge to wa_otp_fast_dispatch_invoke right before returning, wrapped so ANY failure
-- (secret not yet provisioned, network, Edge Function down) is swallowed, never surfaced to the
-- caller and never rolls back anything already committed above — the cron sweep remains the
-- unconditional safety net exactly as before this migration.
create or replace function public.request_customer_link_code(p_mobile text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_generic jsonb := jsonb_build_object('status', 'ok', 'message', 'If that number is registered, a verification code was sent on WhatsApp.');
  v_phone_hash text;
  v_phone_last4 text;
  v_match_id uuid;
  v_match_org_id uuid;
  v_match_primary_profile_id uuid;
  v_match_is_test boolean;
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
    select id, org_id, primary_profile_id, is_test, preferred_language
    into v_match_id, v_match_org_id, v_match_primary_profile_id, v_match_is_test, v_match_preferred_language
    from public.customers where mobile = p_mobile;
  end if;

  if v_match_count <> 1
     or v_match_primary_profile_id is not null
     or v_match_is_test then
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

  -- CHANGE (a): 'code' alongside 'body' — the dispatcher needs the raw code as a value, not just
  -- embedded in a rendered sentence, for a future named-parameter template send. Both keys are
  -- wiped together the moment this row is redacted (the existing redaction code replaces the
  -- WHOLE payload column, not a per-key merge — see wa-milestone-dispatch-core.ts /
  -- wa-dispatch-v2.ts), so adding this key does not widen how long the plaintext code survives.
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

  -- CHANGE (b): the fast-dispatch nudge. See wa_otp_fast_dispatch_invoke's own header comment for
  -- why this exists and why its failure is swallowed rather than surfaced or rolled back.
  begin
    perform public.wa_otp_fast_dispatch_invoke(v_match_org_id);
  exception when others then
    null;
  end;

  return v_generic;
end;
$$;

revoke all on function public.request_customer_link_code(text) from public, anon;
grant execute on function public.request_customer_link_code(text) to authenticated;
$migration$;
  v_embedded_test text := $testbody$-- Rolled-back test for 20261120100100_customer_link_otp_fast_dispatch.sql. The runner
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
$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;
  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded test text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  -- 4. LIVE-DEFINITION PRE-CHECKS: the base migration (20261120100000) must already be live --
  -- this delta only redefines its functions, it never creates the tables or the original
  -- functions from scratch.
  if to_regclass('public.customer_link_otp_settings') is null
     or to_regclass('public.customer_link_otp_challenges') is null
     or to_regclass('public.customer_link_otp_send_log') is null then
    raise exception 'APPLY_REFUSED: the base migration (20261120100000) is not live -- its 3 tables do not all exist';
  end if;
  if to_regprocedure('public.is_customer_link_otp_enabled()') is null
     or to_regprocedure('public.request_customer_link_code(text)') is null
     or to_regprocedure('public.verify_customer_link_code(text)') is null then
    raise exception 'APPLY_REFUSED: the base migration (20261120100000) is not live -- its 3 functions do not all exist';
  end if;
  if to_regprocedure('public.wa_otp_fast_dispatch_invoke(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.wa_otp_fast_dispatch_invoke(uuid) already exists before this migration ran';
  end if;

  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select c.id::text || ':' || c.mobile || ':' || coalesce(c.primary_profile_id::text, '-') || ':' || c.phone_verified::text as x
    from public.customers c where c.name not like '\_\_TEST\_%' escape '\'
    union all
    select p.id::text from public.profiles p where p.full_name not like '\_\_TEST\_%' escape '\'
    union all
    select o.id::text || ':' || coalesce(o.payload::text, '') from public.whatsapp_outbox o
    where o.ref_type is distinct from 'customer_link_otp' and o.customer_id in (select id from public.customers where name not like '\_\_TEST\_%' escape '\')
  ) r;

  -- 4. RUN -- apply the pinned delta migration verbatim (create-or-replace, idempotent), then the test.
  execute replace(v_embedded_migration, E'\r', '');

  begin
    execute replace(v_embedded_test, E'\r', '');
  exception when others then
    v_inner_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select c.id::text || ':' || c.mobile || ':' || coalesce(c.primary_profile_id::text, '-') || ':' || c.phone_verified::text as x
    from public.customers c where c.name not like '\_\_TEST\_%' escape '\'
    union all
    select p.id::text from public.profiles p where p.full_name not like '\_\_TEST\_%' escape '\'
    union all
    select o.id::text || ':' || coalesce(o.payload::text, '') from public.whatsapp_outbox o
    where o.ref_type is distinct from 'customer_link_otp' and o.customer_id in (select id from public.customers where name not like '\_\_TEST\_%' escape '\')
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', both embedded-text sha256 hashes verified'
    || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\nok   delta migration applied inside this still-open transaction (create-or-replace, idempotent)'
    || E'\n--- embedded test output ---' || E'\n' || coalesce(v_inner_result, '(test raised no exception -- unexpected, it should always end in RAISE EXCEPTION RESULTS:...)') || E'\n--- end embedded test output ---'
    || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real-organisation fingerprint CHANGED -- this rehearsal mutated real data'
         else 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data' end;

  raise exception E'RESULTS:\n%', res;
end
$rehearsal$;
