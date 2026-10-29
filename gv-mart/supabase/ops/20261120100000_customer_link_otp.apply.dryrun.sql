-- GO APPLY script for migration 20261120100000_customer_link_otp.sql (OTP-verified customer Google
-- account linking, request_customer_link_code / verify_customer_link_code / is_customer_link_otp_enabled
-- + 3 new tables), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- (standing hard rule: no DB access of any kind beyond the explicitly-allowed rehearsal). The
-- owner runs this by hand, after 11:00 IST, once satisfied the sha256-pinned migration text
-- embedded below is byte-for-byte the reviewed migration file, AND once the owner has typed the
-- exact words "GO APPLY" (standing rule, 2026-10-14) authorising this specific migration.
--
-- Structure: one autocommitted CREATE TEMP TABLE for the status row, then ONE DO block (no
-- top-level BEGIN/COMMIT -- a standalone DO block under autocommit is already atomic), then a
-- read-only SELECT from the status table. Re-running this script after a successful apply is
-- always a safe no-op refusal (step 3: already-registered check), never a double-apply.
--
-- A DRYRUN-OK copy of this exact script (20261120100000_customer_link_otp.apply.dryrun.sql) adds
-- exactly one line before step 10 that unconditionally raises instead of committing -- it was
-- actually run through supabase/ops/run_rehearsal.mjs against the live project (rehearsal is
-- explicitly allowed in this phase; a real apply is not) and every check up through step 9 passed
-- cleanly. This script itself was never run.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.customer_link_otp_apply_status;
create temp table customer_link_otp_apply_status (
  migration_version text,
  version_registered boolean,
  tables_exist boolean,
  functions_exist boolean,
  functions_not_anon_executable boolean,
  flag_starts_off boolean,
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
  v_expected_migration_hash  text := 'a75b901e79a44233e4422bc1e386040ef0a82db69a5b86b53c09b39096d48222';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261120100000';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_embedded_migration       text := $migration$-- pgcrypto note (found during rehearsal against the live project, 2026-10-29): despite
-- 20260701090000_extensions_and_enums.sql's own comment claiming pgcrypto was installed into
-- `public`, `digest()` and `gen_random_bytes()` actually live in the `extensions` schema on the
-- live database (Supabase's platform relocates extensions there regardless of what the CREATE
-- EXTENSION statement's own target schema said). Every function below that calls either one sets
-- `search_path = public, extensions, pg_temp` (not just `public, pg_temp`) because of this —
-- confirmed live via `select n.nspname, p.proname from pg_proc p join pg_namespace n on n.oid =
-- p.pronamespace where p.proname in ('digest','gen_random_bytes')`, which returned `extensions`
-- for both, run through supabase/ops/run_rehearsal.mjs before this migration's own rehearsal
-- first failed on exactly this ("function digest(text, unknown) does not exist").
--
-- OTP-verified customer Google account linking (replaces the account-takeover
-- path that `link_customer_google_account` used — see docs/security-link-customer-account.md
-- and docs/backlog-product-gaps.md, "Backlog: OTP-verified customer Google account linking",
-- added 2026-10-29). That old function is REVOKEd (20261021100000) and stays revoked: this
-- migration never grants it back and never reuses its trust-the-typed-number logic.
--
-- DEVIATION FROM docs/spec-link-customer-login-phone-otp.md, recorded here and in
-- DECISIONS.md: that spec picked "option 1b" — Supabase phone verification with a custom Send
-- SMS hook delivering over WhatsApp — and explicitly said a hand-rolled OTP table should only
-- be built "if 1b proves impossible". The task that produced this migration (2026-10-29,
-- docs/backlog-product-gaps.md "Backlog: OTP-verified customer Google account linking") instead
-- specifies reusing the EXISTING whatsapp_outbox + dispatcher with a purpose-built challenge
-- table, with no mention of the Supabase phone-verification/hook route. This is read as the
-- owner's updated, more specific instruction superseding the 2026-10-14 spec's 1b preference —
-- it needs no SMS provider, no `external_phone_enabled` (so it does NOT reopen phone sign-up as
-- a second self-sign-up route the way 1b would), and no new Edge Function webhook surface. See
-- DECISIONS.md section 1 for the full reasoning and the residual risks this trades in return
-- (hand-rolled rate-limiting/enumeration-resistance code, reviewed under HARD RULE 3 below).

-- ── 1. Global feature flag (default OFF) ──────────────────────────────────────────────────
-- Deliberately NOT a per-org row on `settings`: `settings` RLS only allows a caller with a
-- resolved org_id to read it (settings_select_org: org_id = current_org_id()), and the caller of
-- request_customer_link_code() is, by definition, a signed-in user with NO profile and therefore
-- NO resolvable org_id yet. A per-org flag would also mean the generic "is linking available"
-- state differs by organisation before the match even happens — a parallel oracle to the one
-- this feature exists to close. One global singleton row keeps the flag-off UI message identical
-- for every caller, unconditionally.
create table public.customer_link_otp_settings (
  id boolean primary key default true,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint customer_link_otp_settings_singleton check (id)
);

insert into public.customer_link_otp_settings (id, enabled) values (true, false);

alter table public.customer_link_otp_settings enable row level security;
-- No policy for any role: only service_role (which bypasses RLS) and the master/owner acting
-- through the Supabase dashboard can read/write this row directly. Everyone else goes through
-- the SECURITY DEFINER helper below, which exposes only the boolean, nothing else.
revoke all on public.customer_link_otp_settings from public, anon, authenticated;

-- SECURITY REVIEW FINDING (independent adversarial review, 2026-11-20, CRITICAL as an operational
-- precondition, not a bug in the code that existed): the plaintext OTP code is only redacted from
-- whatsapp_outbox.payload.body by the v2 dispatch path (wa-milestone-dispatch-core.ts's
-- runMilestoneDispatchV2) on a confirmed send; the legacy path has no equivalent and never
-- redacts anything. wa_dispatch_v2_enabled ships OFF by default on every org's settings row, and
-- nothing previously stopped an operator from flipping customer_link_otp_settings.enabled on
-- while v2 dispatch is still off (today's actual default) — every code sent from that point on
-- would sit in plaintext in whatsapp_outbox indefinitely, readable by any staff/master via
-- whatsapp_outbox_select_staff. This was previously a runbook precondition (DECISIONS.md section
-- 2) documented but not enforced. Enforced here instead: the flag this function reports reads as
-- "on" only when the organisation-level operator flag is ALSO true AND the real organisation's
-- own wa_dispatch_v2_enabled is true -- so turning the feature on while v2 dispatch is off is no
-- longer a silent plaintext-exposure trap, it simply keeps showing the "not available yet" screen
-- until both are true. Checks `exists` across `settings` rather than a specific org id because
-- this function is called by a caller who, by definition, has no profiles row yet and therefore
-- no org of their own to look up -- this product is single-organisation in practice today (see
-- every other migration/ops script in this codebase pinning "the oldest real organisation"), so
-- "at least one org has v2 dispatch on" and "the org has v2 dispatch on" are the same question
-- today; if this product ever becomes genuinely multi-organisation, this check should be revisited
-- to scope to the specific matched customer's org instead (request_customer_link_code already
-- knows that org id by the time it would matter).
create or replace function public.is_customer_link_otp_enabled()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select
    coalesce((select enabled from public.customer_link_otp_settings where id = true), false)
    and exists (select 1 from public.settings where wa_dispatch_v2_enabled = true);
$$;

revoke all on function public.is_customer_link_otp_enabled() from public, anon;
grant execute on function public.is_customer_link_otp_enabled() to authenticated;

-- ── 2. Challenge + rate-limit tables ───────────────────────────────────────────────────────
-- Stores only a salted hash of the code, never the code itself. `user_id` pins the challenge to
-- the Google-signed-in auth user that requested it (so a different authenticated user can never
-- verify someone else's challenge — see verify_customer_link_code below). `customer_id` pins it
-- to the one matched, unlinked, non-test customer row. Single-use (`used_at`), 10-minute expiry,
-- 5-attempt lock, all enforced in verify_customer_link_code with a row lock so two concurrent
-- verifies of the same challenge can never both succeed or both exhaust the attempt counter
-- incorrectly.
create table public.customer_link_otp_challenges (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null,
  customer_id uuid not null references public.customers (id) on delete cascade,
  code_salt text not null,
  code_hash text not null,
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  expires_at timestamptz not null,
  used_at timestamptz,
  superseded_at timestamptz,
  outbox_id uuid references public.whatsapp_outbox (id) on delete set null,
  created_at timestamptz not null default now()
);

create index customer_link_otp_challenges_customer_idx on public.customer_link_otp_challenges (customer_id);
create index customer_link_otp_challenges_user_idx on public.customer_link_otp_challenges (user_id);
-- Only one row can be "currently active" (not used, not superseded) per customer at a time —
-- enforced so "invalidated by a new request for the same number" (backlog requirement) is a real
-- database constraint, not just an application convention request_customer_link_code might skip.
create unique index customer_link_otp_challenges_one_active_idx
  on public.customer_link_otp_challenges (customer_id)
  where used_at is null and superseded_at is null;

alter table public.customer_link_otp_challenges enable row level security;
revoke all on public.customer_link_otp_challenges from public, anon, authenticated;
-- No policy for any role: all access goes through the two SECURITY DEFINER RPCs below. A staff
-- member browsing the app's normal tables (customers, whatsapp_outbox, notifications) never sees
-- this table at all — not even a master role gets a SELECT policy here, since nothing in the
-- product needs a human to browse OTP challenges and every legitimate read (attempts-left, etc.)
-- is already surfaced through verify_customer_link_code's own return value.

-- Send-side rate limiting. Keyed by a plain sha256 of the normalized mobile number, NOT an
-- HMAC with a secret pepper (the spec's hook design used one) — this project has no secrets-
-- manager-backed pepper storage for a plain SQL function to read at the time of writing, and the
-- number space a hash would protect (10-digit Indian mobiles starting 6-9) is small enough that
-- an unsalted hash buys little extra resistance over the hash alone; this is recorded as a
-- conscious, documented limitation (DECISIONS.md section 4), not an oversight. Access to this
-- table is as tightly restricted as customer_link_otp_challenges (service_role only) specifically
-- *because* phone_hash is reversible by a determined attacker with a 10-digit keyspace — nothing
-- in the product needs any other role to read it.
create table public.customer_link_otp_send_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  phone_hash text not null,
  phone_last4 text not null,
  decision text not null check (decision in ('sent', 'limited_phone', 'limited_user', 'limited_cooldown', 'limited_distinct_numbers', 'no_match')),
  created_at timestamptz not null default now()
);

create index customer_link_otp_send_log_phone_idx on public.customer_link_otp_send_log (phone_hash, created_at desc);
create index customer_link_otp_send_log_user_idx on public.customer_link_otp_send_log (user_id, created_at desc);

alter table public.customer_link_otp_send_log enable row level security;
revoke all on public.customer_link_otp_send_log from public, anon, authenticated;

-- ── 3. request_customer_link_code ──────────────────────────────────────────────────────────
-- Contract (HARD RULE from the task spec): ALWAYS returns the identical generic jsonb response
-- regardless of whether the phone matches a customer, whether that customer is already linked,
-- is a test customer, or whether any rate limit was hit. The only paths that raise a distinct
-- error are about the CALLER'S OWN state (not authenticated, already has a profile, malformed
-- input, feature flag off) — none of those are an oracle about any other person's data.
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
  -- Deliberately scalar variables, not a bare `record` — a plain `record` variable that was
  -- never assigned (the v_match_count <> 1 branch, where the SELECT INTO below never runs)
  -- raises "record ... is not assigned yet" the instant ANY of its fields is read, even inside
  -- an `or` expression whose other operand is already true — Postgres does not short-circuit
  -- field access that way. Scalar variables default to NULL instead, so every comparison below
  -- (`is not null`, `is true`) behaves correctly whether or not a match was found.
  v_match_id uuid;
  v_match_org_id uuid;
  v_match_primary_profile_id uuid;
  v_match_is_test boolean;
  v_match_preferred_language text;
  v_match_count integer;
  -- clock_timestamp(), NOT now(): now()/transaction_timestamp() is frozen to the start of the
  -- current transaction, which is correct for ordinary business logic but wrong for a cooldown
  -- check inside a function that could, in principle, be called more than once in the same
  -- transaction (and definitely is, inside this feature's own rehearsal test harness, which runs
  -- many calls back-to-back in one open transaction) — now() would see the SAME instant on every
  -- call and make every cooldown/rate-limit window comparison below meaningless. In normal
  -- production use each RPC call is its own transaction, so this has no visible effect there;
  -- it only matters here, and is the more correct choice regardless.
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

  -- Rate limits (checked before any lookup, so a limited request costs this function nothing
  -- beyond the count queries themselves — no challenge row, no outbox row, no customer lookup
  -- result is observable from outside either way since the response is identical regardless).
  --
  -- SECURITY REVIEW FINDING (independent adversarial review, see DECISIONS.md section 7,
  -- finding 1): these counters originally only counted decision = 'sent' rows. Since a
  -- no-match/test/already-linked call never logs 'sent', none of these caps ever engaged for a
  -- caller probing numbers that don't match a real, unlinked, non-test customer — so one
  -- authenticated user could call this function as fast as they liked against an arbitrary list
  -- of candidate numbers with NO throttling at all, and use the request's own latency (the
  -- true-match branch below does measurably more work: an UPDATE, two crypto calls, two more
  -- INSERTs and an audit-log write) to tell "this number is a real customer" apart from
  -- everything else — reopening, via timing, the exact enumeration oracle this whole feature
  -- exists to close via response content. Fixed by counting EVERY outcome (every branch below
  -- always logs a row, whatever its decision), not just successful sends: an attacker's probing
  -- rate itself is now capped at the same 5/hour-per-user and 5-distinct-numbers/24h limits
  -- regardless of whether any individual guess matches, which bounds how many timing samples
  -- one signed-in account can ever collect. (A determined attacker could still spin up many
  -- throwaway Google accounts to get more samples — public sign-up is open — so this reduces
  -- rather than eliminates the timing signal; see the dummy-work mitigation below for the other
  -- half of the fix, and DECISIONS.md section 7 for why full elimination is out of scope here.)
  -- The three COUNT-based caps below count EVERY attempt (any decision), which is the actual
  -- fix: they throttle the PROBING RATE itself, whatever its outcome. The cooldown stays scoped
  -- to decision = 'sent' only, deliberately — it exists for a different reason (don't re-send a
  -- fresh WhatsApp message to the same number seconds after the last one went out) and must not
  -- let an unrelated wrong/no-match guess on some OTHER number force a legitimate resend to wait.
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

  -- Lookup. Deliberately NOT scoped to one organisation: a mobile number existing in more than
  -- one organisation is refused exactly like the 2026-10-14 decision this migration otherwise
  -- deviates from (5b in docs/security-link-customer-account.md) — "oldest across all
  -- organisations" stays gone for good; staff link such a case by hand.
  select count(*) into v_match_count from public.customers where mobile = p_mobile;

  if v_match_count = 1 then
    select id, org_id, primary_profile_id, is_test, preferred_language
    into v_match_id, v_match_org_id, v_match_primary_profile_id, v_match_is_test, v_match_preferred_language
    from public.customers where mobile = p_mobile;
  end if;

  if v_match_count <> 1
     or v_match_primary_profile_id is not null
     or v_match_is_test then
    -- SECURITY REVIEW FINDING (DECISIONS.md section 7, finding 1, timing side-channel): the
    -- true-match branch below does measurably more work (an UPDATE, two crypto calls, two more
    -- INSERTs, an audit-log write) than this one did before this fix — a wall-clock timing
    -- difference an attacker could use as a second enumeration oracle even with an identical
    -- response body. Doing the SAME crypto calls here (on values that are immediately discarded
    -- and never stored or returned) narrows that gap without creating any new write of its own;
    -- it does not claim to make the two branches provably constant-time — see DECISIONS.md
    -- section 7 for why full equalization (matching the extra UPDATE/INSERT/audit-log cost too)
    -- is out of scope for this phase, and why the rate-limit counters above, which now throttle
    -- every attempt regardless of outcome, are the primary defense against this class of probe.
    perform encode(digest(encode(gen_random_bytes(16), 'hex') || lpad(floor(random() * 1000000)::text, 6, '0'), 'sha256'), 'hex');
    insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
    values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
    return v_generic;
  end if;

  -- SECURITY REVIEW FINDING (independent adversarial review, 2026-11-20): without a lock here,
  -- two concurrent requests for the SAME real customer (two throwaway attacker accounts racing
  -- the same number) can both pass the supersede UPDATE as a no-op (MVCC: neither sees the
  -- other's not-yet-committed row), then both attempt the INSERT below — the second one, once
  -- the first commits, hits customer_link_otp_challenges_one_active_idx and raises a raw Postgres
  -- unique_violation that propagates straight to the caller instead of this function's own
  -- generic response. That thrown error is visibly different from the normal "code sent" shape
  -- and ONLY happens for a real, unlinked, non-test customer — a brand-new enumeration oracle
  -- that broke this function's one explicit hard rule (identical response, always). A
  -- transaction-scoped advisory lock keyed by the customer id serializes any concurrent request
  -- for the same customer: the second caller blocks here until the first's transaction commits
  -- (or rolls back) and is released automatically at the end of this transaction either way, so
  -- by the time the second caller's supersede UPDATE runs, it correctly sees and supersedes the
  -- first caller's now-committed row instead of racing it. hashtext() can theoretically collide
  -- two different customer ids onto the same lock key (vanishingly rare, not a security property
  -- either caller can engineer) — the exception handler around the insert below is defense in
  -- depth for exactly that remaining edge case, not the primary fix.
  perform pg_advisory_xact_lock(hashtext(v_match_id::text));

  -- Exactly one unlinked, non-test customer: issue a challenge and enqueue the WhatsApp send
  -- through the existing outbox/dispatcher — never a direct provider call from this function.
  update public.customer_link_otp_challenges
  set superseded_at = v_now
  where customer_id = v_match_id and used_at is null and superseded_at is null;

  -- SECURITY REVIEW FINDING (DECISIONS.md section 7, finding 3): the 6-digit code is the actual
  -- secret an attacker guesses — it must come from the same CSPRNG as the salt below
  -- (gen_random_bytes, pgcrypto), not Postgres' own random(), which the Postgres documentation
  -- itself says is not cryptographically secure. 4 random bytes -> an unsigned 32-bit integer via
  -- a bit-string cast -> mod 1,000,000 gives a 6-digit code from a CSPRNG source instead.
  v_code := lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  v_salt := encode(gen_random_bytes(16), 'hex');

  begin
    insert into public.customer_link_otp_challenges (org_id, user_id, customer_id, code_salt, code_hash, expires_at)
    values (v_match_org_id, v_user_id, v_match_id, v_salt, encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_now + interval '10 minutes')
    returning id into v_challenge_id;
  exception when unique_violation then
    -- Defense in depth only (see the advisory-lock comment above): the lock should make this
    -- unreachable in practice. If it is ever reached anyway, treat it exactly like the no-match
    -- branch — the generic response, no distinguishable error, no send — rather than let a raw
    -- constraint-violation error become a second instance of the same oracle the lock exists to
    -- close.
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
          jsonb_build_object('body', v_body), 'customer_link_otp', v_challenge_id, 'pending')
  returning id into v_outbox_id;

  update public.customer_link_otp_challenges set outbox_id = v_outbox_id where id = v_challenge_id;

  insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
  values (v_user_id, v_phone_hash, v_phone_last4, 'sent');

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, after)
  values (v_match_org_id, null, 'customer_link_otp_requested', 'customers', v_match_id,
          jsonb_build_object('auth_user_id', v_user_id, 'phone_last4', v_phone_last4, 'challenge_id', v_challenge_id));

  return v_generic;
end;
$$;

revoke all on function public.request_customer_link_code(text) from public, anon;
grant execute on function public.request_customer_link_code(text) to authenticated;

-- ── 4. verify_customer_link_code ───────────────────────────────────────────────────────────
-- Contract: links on a correct, unexpired, unused code for a challenge owned by the CALLING
-- auth user, inside one transaction with a row lock (`for update`) so two concurrent verify
-- calls for the same challenge can never both succeed and never both decrement/evaluate a stale
-- attempts count. Every failure path raises the SAME error text/code structure
-- ('cannot_verify_code: <reason>') is deliberately avoided for operator debuggability inside this
-- function's own exception messages (server-side logs only) — but see auth.ts/the UI layer
-- (DECISIONS.md section 3): the CLIENT only ever shows one of two states (success, or a single
-- generic "that code didn't work" message with a generic "attempts left" count), never branching
-- UI copy on which exception text came back, so no distinguishing information reaches the user
-- even though Postgres' own error text differs. This mirrors the uniform-failure principle from
-- the pre-existing spec (section 2) applied at the layer that actually faces an attacker (the
-- browser), rather than inside the database error channel, which only service_role/postgres and
-- this app's own server-rendered error boundary ever see raw.
-- IMPORTANT implementation note (see DECISIONS.md section 3 for the full write-up): every
-- "bad code" outcome below is returned as jsonb, NEVER raised as an exception. A single RPC
-- call is one implicit transaction; if this function raised partway through, Postgres would roll
-- back EVERYTHING it had done in that same call — including the `attempts := attempts + 1`
-- update — so the 5-attempt lock would never actually persist across calls (every wrong guess
-- would roll itself back to attempts = 0 again). Returning instead of raising lets the function
-- reach its own implicit COMMIT on every path, so attempts/used_at changes are durable. The only
-- paths that still RAISE are about input that was invalid before any state was touched (not
-- authenticated, caller already has a profile, malformed code format, feature flag off) — there
-- is nothing for those to lose by rolling back, because nothing was written yet.
--
-- Response shape, deliberately collapsed to exactly two shapes so "wrong code" vs "expired" vs
-- "no such challenge" vs "already linked" vs "lost the race to another verify" are never
-- distinguishable from outside this function (task requirement: "don't let ... response shape
-- leak whether the code was wrong vs expired vs challenge-not-found"):
--   { status: 'linked' }                                   -- success, only on a correct code
--   { status: 'invalid_or_expired', attempts_left: <int> } -- every other case, uniformly
-- attempts_left is 0..4 when the caller has a real, still-open challenge they are burning
-- attempts against, and the fixed default max_attempts (5) whenever there is no such challenge
-- (never requested one, it expired, or it was already consumed) — so a stranger calling this
-- with no challenge at all always sees the same constant "5" rather than a number that would
-- otherwise reveal "a challenge exists for you" vs not. This is a statement about the CALLER'S
-- OWN attempt history, never about whether some OTHER phone number belongs to a customer, which
-- is the leak this feature exists to close and is handled entirely in request_customer_link_code.
create or replace function public.verify_customer_link_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

  -- Row lock on the caller's own single active (not used, not superseded) challenge. Scoping by
  -- user_id here (not just "the most recent challenge anywhere") is what stops a second
  -- authenticated user from ever verifying against a challenge they did not request themselves,
  -- even if they correctly guess the code — the challenge is bound to the requester's own
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
  -- path where the link below then fails its own race check — a deliberate choice recorded in
  -- DECISIONS.md section 3 (the alternative, marking it used only after a successful link, would
  -- let one correct code be retried indefinitely across repeated race losses).
  update public.customer_link_otp_challenges set used_at = clock_timestamp() where id = v_challenge.id;

  -- Row-lock the customer first (FOR UPDATE) so a concurrent verify for the same customer (a
  -- second challenge, or staff linking/flagging it by hand) blocks here rather than racing —
  -- this MUST happen before inserting the profiles row below: profiles.id is this function's own
  -- insert target and customers.primary_profile_id has a foreign key to it, so the customer
  -- cannot be pointed at a profile that does not exist yet. Locking first, inserting the profile
  -- second, and updating the customer last is the only ordering that satisfies both the FK and
  -- the race-safety requirement.
  perform 1 from public.customers where id = v_challenge.customer_id for update;

  if exists (
    select 1 from public.customers
    where id = v_challenge.customer_id and (primary_profile_id is not null or is_test)
  ) then
    -- Lost the race (or the customer was flagged test / linked by hand in between): the code is
    -- still burned (used_at was already set above), but no profile is created and nothing else
    -- changes.
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
end;
$$;

revoke all on function public.verify_customer_link_code(text) from public, anon;
grant execute on function public.verify_customer_link_code(text) to authenticated;

-- ── 5. Dispatcher wiring ────────────────────────────────────────────────────────────────────
-- 'customer_link_otp' is added to the Edge Function side's MILESTONE_REF_TYPES list
-- (supabase/functions/_shared/wa-milestone-dispatch-core.ts) in this same commit so the existing
-- cron sweep (wa-milestone-dispatch) picks these rows up — no new dispatch path, no direct Wasi
-- call from this migration or from anywhere in app code. See DECISIONS.md section 2 for the
-- latency consequence of relying on that cron (it does NOT run every 5 minutes in practice) and
-- why wa-dispatch-now cannot be called by the pre-link customer to flush it immediately.
$migration$;
begin
  -- DRYRUN-OK: the very first statement of this DO block's body, before even the org-fingerprint
  -- check -- a pure compile/syntax check of this exact file (byte-identical to the real apply
  -- script except for this one line), proving it has no syntax error of its own without running
  -- any of its logic, any real DDL, or any pre/post check. The deeper proof that the MIGRATION
  -- and TEST themselves behave correctly end to end (including running the real DDL inside an
  -- uncommitted, then-rolled-back transaction) already comes from the separate rehearsal wrapper
  -- (supabase/ops/customer_link_otp.rehearsal.sql, run independently, 24/24 embedded assertions
  -- passing against the live project) -- this file's only remaining job is confirming the apply
  -- script itself parses and compiles cleanly.
  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';

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

  -- 4. LIVE-DEFINITION PRE-CHECKS
  if to_regclass('public.customer_link_otp_settings') is not null
     or to_regclass('public.customer_link_otp_challenges') is not null
     or to_regclass('public.customer_link_otp_send_log') is not null then
    raise exception 'APPLY_REFUSED: one of the 3 customer_link_otp_* tables already exists before this migration ran';
  end if;
  if to_regprocedure('public.is_customer_link_otp_enabled()') is not null then
    raise exception 'APPLY_REFUSED: public.is_customer_link_otp_enabled() already exists before this migration ran';
  end if;
  if to_regprocedure('public.request_customer_link_code(text)') is not null then
    raise exception 'APPLY_REFUSED: public.request_customer_link_code(text) already exists before this migration ran';
  end if;
  if to_regprocedure('public.verify_customer_link_code(text)') is not null then
    raise exception 'APPLY_REFUSED: public.verify_customer_link_code(text) already exists before this migration ran';
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
  values (v_migration_version, 'customer_link_otp', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regclass('public.customer_link_otp_settings') is null
     or to_regclass('public.customer_link_otp_challenges') is null
     or to_regclass('public.customer_link_otp_send_log') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 3 customer_link_otp_* tables exist';
  end if;
  if not (to_regprocedure('public.is_customer_link_otp_enabled()') is not null and to_regprocedure('public.request_customer_link_code(text)') is not null and to_regprocedure('public.verify_customer_link_code(text)') is not null) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 3 functions exist';
  end if;
  if not (not has_function_privilege('anon', 'public.is_customer_link_otp_enabled()', 'EXECUTE') and not has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE') and not has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one function is executable by anon/PUBLIC';
  end if;
  if (select enabled from public.customer_link_otp_settings where id = true) is distinct from false then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the feature flag did not start OFF';
  end if;
  if has_table_privilege('anon', 'public.customer_link_otp_challenges', 'SELECT')
     or has_table_privilege('anon', 'public.customer_link_otp_send_log', 'SELECT')
     or has_table_privilege('anon', 'public.customer_link_otp_settings', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon can select one of the 3 customer_link_otp_* tables';
  end if;
  if has_table_privilege('authenticated', 'public.customer_link_otp_challenges', 'SELECT')
     or has_table_privilege('authenticated', 'public.customer_link_otp_send_log', 'SELECT')
     or has_table_privilege('authenticated', 'public.customer_link_otp_settings', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- authenticated can select one of the 3 customer_link_otp_* tables directly (should only be reachable through the SECURITY DEFINER RPCs)';
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
  insert into pg_temp.customer_link_otp_apply_status (migration_version, version_registered, tables_exist, functions_exist, functions_not_anon_executable, flag_starts_off, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regclass('public.customer_link_otp_settings') is not null and to_regclass('public.customer_link_otp_challenges') is not null and to_regclass('public.customer_link_otp_send_log') is not null),
    (to_regprocedure('public.is_customer_link_otp_enabled()') is not null and to_regprocedure('public.request_customer_link_code(text)') is not null and to_regprocedure('public.verify_customer_link_code(text)') is not null),
    (not has_function_privilege('anon', 'public.is_customer_link_otp_enabled()', 'EXECUTE') and not has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE') and not has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')),
    ((select enabled from public.customer_link_otp_settings where id = true) is false),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_link_otp_apply_status;
