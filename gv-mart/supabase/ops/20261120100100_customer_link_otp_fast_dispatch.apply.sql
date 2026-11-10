-- GO APPLY script for migration 20261120100100_customer_link_otp_fast_dispatch.sql
-- (fast WhatsApp OTP dispatch path: wa_otp_fast_dispatch_invoke + is_customer_link_otp_enabled's
-- wa_dispatch_v2_scope precondition + request_customer_link_code's 'code' payload key and
-- fast-dispatch nudge), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- (standing hard rule: no DB access of any kind beyond the explicitly-allowed rehearsal). The
-- owner runs this by hand, after 11:00 IST, once satisfied the sha256-pinned migration text
-- embedded below is byte-for-byte the reviewed migration file, AND once the owner has typed the
-- exact words "applied" authorising this specific migration.
--
-- This delta deliberately does NOT insert a whatsapp_event_templates row for 'lexdraft_otp' or
-- any other template -- that mapping is held pending the owner's brand-neutrality confirmation
-- of that template. Step 9's post-apply checks assert no such row exists after this script runs.
--
-- Re-running this script after a successful apply is always a safe no-op refusal (step 3:
-- already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.customer_link_otp_fast_dispatch_apply_status;
create temp table customer_link_otp_fast_dispatch_apply_status (
  migration_version text,
  version_registered boolean,
  function_exists boolean,
  function_not_anon_executable boolean,
  flag_still_off boolean,
  no_template_mapping boolean,
  newly_leaked_functions text[],
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := 'a6bc5b6050841f5831ecc411c09c570abecb951dcec9f861f714788117eff4f0';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261120100100';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_embedded_migration       text := $migration$-- Phase 2, Item 2 of the customer-OTP-link feature (docs/backlog-product-gaps.md): a fast
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
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered -- stop, nothing applied', v_migration_version;
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

  -- 5. LEAK SNAPSHOT (BEFORE)
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 6. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_link_otp_fast_dispatch', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regprocedure('public.wa_otp_fast_dispatch_invoke(uuid)') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- wa_otp_fast_dispatch_invoke(uuid) does not exist';
  end if;
  if has_function_privilege('anon', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- wa_otp_fast_dispatch_invoke is executable by anon or authenticated (should be revoked from both -- only called internally by request_customer_link_code)';
  end if;
  if has_function_privilege('anon', 'public.is_customer_link_otp_enabled()', 'EXECUTE')
     or has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the original 3 RPCs became anon-executable after this delta ran';
  end if;
  if (select enabled from public.customer_link_otp_settings where id = true) is distinct from false then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the feature flag is not OFF (this delta must never flip it)';
  end if;
  if exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- a customer_link_otp whatsapp_event_templates row exists; this delta must never wire a template mapping (held pending owner brand-neutrality confirmation)';
  end if;

  -- 9x. DIFF-BASED leak check -- only NEW anon/PUBLIC-executable functions fail this.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (select unnest(v_leaked_after) as x except select unnest(v_leaked_before)) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 9y. real-organisation fingerprint unchanged.
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.customer_link_otp_fast_dispatch_apply_status (migration_version, version_registered, function_exists, function_not_anon_executable, flag_still_off, no_template_mapping, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regprocedure('public.wa_otp_fast_dispatch_invoke(uuid)') is not null),
    (not has_function_privilege('anon', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE') and not has_function_privilege('authenticated', 'public.wa_otp_fast_dispatch_invoke(uuid)', 'EXECUTE')),
    ((select enabled from public.customer_link_otp_settings where id = true) is false),
    (not exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_link_otp_fast_dispatch_apply_status;
