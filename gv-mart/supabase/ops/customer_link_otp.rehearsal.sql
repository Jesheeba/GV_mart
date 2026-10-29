-- Rehearsal wrapper for 20261120100000_customer_link_otp.sql +
-- supabase/tests/customer_link_otp.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- except through the project's approved Management-API runner (supabase/ops/run_rehearsal.mjs,
-- sha256-verified before use), and only as a REHEARSAL: this block always ends in RAISE
-- EXCEPTION, so nothing it does can ever commit, regardless of pass/fail. Modeled byte-for-byte
-- on the project's own existing convention (see git history:
-- supabase/ops/technician_pending_reviews.rehearsal.sql on feat/technician-pending-reviews),
-- with the gate hour taken from THIS task's explicit instruction (11:00 IST), not that older
-- file's original 18:00 (later migrations in this repo's history moved every such gate to
-- 11:00 IST to match the apply-script convention; this one is written directly at 11:00).
--
-- Six guarantees, in order:
--   0. ORG CHECK  -- the oldest real (non __TEST_) organisation's id+name must hash to the exact
--      md5 recorded below, so this never runs against the wrong project.
--   1. LOCK       -- lock_timeout = 5s for this transaction only.
--   2. GATE       -- refuses before 11:00 IST.
--   3. PIN        -- sha256(embedded migration text) and sha256(embedded test text) must each
--      equal the hash recorded below; a silent edit of EITHER file after review refuses the
--      whole rehearsal, nothing executed.
--   4. RUN        -- applies the pinned migration text verbatim (five new tables + four new
--      functions, all additive -- no existing table/column/RLS is touched), then executes the
--      pinned test text verbatim as its own nested DO block and captures its RESULTS line. Both
--      run inside this same transaction, which this wrapper's own final line ALWAYS ends with an
--      unconditional RAISE EXCEPTION.
--   5. PROVE      -- a fingerprint of every REAL, non-__TEST_ row across customers / profiles /
--      whatsapp_outbox (the only pre-existing tables this migration's functions ever write to)
--      is taken before step 4 and again after the test's RESULTS exception is caught, and the
--      two are compared and appended to the final result.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash text := '40b96789a5229f360f9f327614be1511d4dceef327022c407ea8e90bbf0c2acf';
  v_expected_test_hash      text := '38a34fe919e371aa6f03c4e2ef05e0c30d9521cd711f842bbb815a73f687bdf5';
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before           text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_migration   text := $migration$-- pgcrypto note (found during rehearsal against the live project, 2026-10-29): despite
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

create or replace function public.is_customer_link_otp_enabled()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select enabled from public.customer_link_otp_settings where id = true), false);
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
  select count(*) into v_user_sends_last_hour
  from public.customer_link_otp_send_log
  where user_id = v_user_id and created_at > v_now - interval '1 hour' and decision = 'sent';

  select count(*) into v_phone_sends_last_hour
  from public.customer_link_otp_send_log
  where phone_hash = v_phone_hash and created_at > v_now - interval '1 hour' and decision = 'sent';

  select max(created_at) into v_last_send_at
  from public.customer_link_otp_send_log
  where user_id = v_user_id and decision = 'sent';

  select count(distinct phone_hash) into v_distinct_numbers_24h
  from public.customer_link_otp_send_log
  where user_id = v_user_id and created_at > v_now - interval '24 hours' and decision = 'sent';

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
    insert into public.customer_link_otp_send_log (user_id, phone_hash, phone_last4, decision)
    values (v_user_id, v_phone_hash, v_phone_last4, 'no_match');
    return v_generic;
  end if;

  -- Exactly one unlinked, non-test customer: issue a challenge and enqueue the WhatsApp send
  -- through the existing outbox/dispatcher — never a direct provider call from this function.
  update public.customer_link_otp_challenges
  set superseded_at = v_now
  where customer_id = v_match_id and used_at is null and superseded_at is null;

  v_code := lpad(floor(random() * 1000000)::text, 6, '0');
  v_salt := encode(gen_random_bytes(16), 'hex');

  insert into public.customer_link_otp_challenges (org_id, user_id, customer_id, code_salt, code_hash, expires_at)
  values (v_match_org_id, v_user_id, v_match_id, v_salt, encode(digest(v_salt || v_code, 'sha256'), 'hex'), v_now + interval '10 minutes')
  returning id into v_challenge_id;

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
  v_embedded_test text := $testbody$-- Rolled-back test for 20261120100000_customer_link_otp.sql (request_customer_link_code /
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
    from unnest(array[v_user_a, v_user_b, v_user_c, v_user_e]) x;

  insert into customers(org_id, name, mobile) values (v_org, '__TEST_customer_real', '9000000011') returning id into v_cust_real;
  insert into profiles(id, org_id, full_name, role) values (v_user_c, v_org, '__TEST_already_linked', 'customer');
  insert into customers(org_id, name, mobile, primary_profile_id) values (v_org, '__TEST_customer_linked', '9000000012', v_user_c) returning id into v_cust_linked;
  insert into customers(org_id, name, mobile, is_test) values (v_org, '__TEST_customer_flagged_test', '9000000013', true) returning id into v_cust_test;

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

  -- ===== G1: anon cannot execute either RPC (defense-in-depth grant check, independent of the
  -- apply-time anon-exposure sweep) =====
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')
    then 'ok   G1 anon cannot execute request_customer_link_code' else 'FAIL G1 anon CAN execute request_customer_link_code' end;
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')
    then 'ok   G2 anon cannot execute verify_customer_link_code' else 'FAIL G2 anon CAN execute verify_customer_link_code' end;

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
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  -- 2. GATE -- 11:00 IST, per this task's explicit instruction.
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this rehearsal only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');

  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded MIGRATION text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded TEST text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  res := res || E'\nok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || E', both embedded-text sha256 hashes verified';

  -- Real-organisation fingerprint BEFORE: every real (non __TEST_) row across customers/
  -- profiles/whatsapp_outbox -- the only pre-existing tables this migration's functions ever
  -- write to (customer_link_otp_* tables are brand new, so a real-row fingerprint of them before
  -- this migration runs is meaningless -- they do not exist yet).
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_before
  from (
    select c.id::text || ':' || c.mobile || ':' || coalesce(c.primary_profile_id::text, '-') || ':' || c.phone_verified::text as x
    from public.customers c
    where c.name not like '\_\_TEST\_%' escape '\'
    union all
    select 'profile:' || p.id::text || ':' || p.role as x
    from public.profiles p
    where p.full_name not like '\_\_TEST\_%' escape '\'
    union all
    select 'outbox:' || o.id::text || ':' || o.status as x
    from public.whatsapp_outbox o
    where o.ref_type is distinct from 'customer_link_otp' -- this migration's own ref_type never existed before it
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before;

  -- 4. RUN
  execute replace(v_embedded_migration, E'\r', '');
  res := res || E'\nok   migration applied inside this still-open transaction';

  begin
    execute replace(v_embedded_test, E'\r', '');
    v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
  exception when others then
    v_inner_result := sqlerrm;
  end;
  res := res || E'\n--- embedded test output ---\n' || coalesce(v_inner_result, '(no result captured)') || E'\n--- end embedded test output ---';

  -- 5. PROVE
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_after
  from (
    select c.id::text || ':' || c.mobile || ':' || coalesce(c.primary_profile_id::text, '-') || ':' || c.phone_verified::text as x
    from public.customers c
    where c.name not like '\_\_TEST\_%' escape '\'
    union all
    select 'profile:' || p.id::text || ':' || p.role as x
    from public.profiles p
    where p.full_name not like '\_\_TEST\_%' escape '\'
    union all
    select 'outbox:' || o.id::text || ':' || o.status as x
    from public.whatsapp_outbox o
    where o.ref_type is distinct from 'customer_link_otp'
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after;
  res := res || E'\n' || case when v_fp_after = v_fp_before
                          then 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data'
                          else 'FAIL real-organisation fingerprint CHANGED -- investigate before trusting anything above' end;

  raise exception E'RESULTS:%', res;
end
$rehearsal$;
