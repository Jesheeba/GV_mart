-- CHAINED rehearsal wrapper for customer_auto_onboard: 20261130100000_customer_auto_onboard_schema.sql,
-- THEN 20261130100001_customer_auto_onboard_rpc.sql, THEN
-- 20261130100002_unlink_blocks_auto_relink.sql, plus the test file
-- (supabase/tests/customer_auto_onboard.test.sql), run in the true apply order, all inside ONE
-- DO block with no top-level BEGIN/COMMIT/SAVEPOINT/ROLLBACK, ending in an unconditional RAISE so
-- nothing here ever persists -- every DDL change and every __TEST_ row from the test run is
-- rolled back by that final raise.
--
-- Refuses before 11:00 IST. Refuses unless the real (non-__TEST_) organisation fingerprint pins
-- to 6f891cf85011f08c2f22fb4a208d21bd. Recomputes sha256 of all four embedded files (encode(sha256
-- (convert_to(text,'UTF8')),'hex') -- explicit UTF8 bytes) and compares against the pinned
-- hashes below, which must match the committed .sql files exactly (LF line endings, no BOM --
-- confirmed on disk before this wrapper was written, same as every other wrapper in this
-- project). Takes a real-org fingerprint of every table these migrations can write to
-- (customers, profiles, audit_log) before and after -- both a plain row count AND a content
-- checksum -- so a same-count-but-mutated-row case is caught too.
--
-- 20261130100002 DOES redefine two already-live functions (admin_link_customer_google_account /
-- admin_unlink_customer_google_account, from 20261121100000, already applied to main) -- unlike
-- the other two migrations here, which only add brand-new objects. No md5-live-definition
-- pre-check is included for those two redefinitions in this wrapper (that mechanism exists in
-- the apply script's own pre/post checks instead, per this project's template); this wrapper's
-- job is to prove the SQL executes correctly and the test matrix passes, not to diff against the
-- live body (the apply script does that part).
do $rehearsal$
declare
  v_now_ist time;
  v_schema_sha256 text := '58487f324dcd17b5d5ac6f5db81b8be5737b18fab2f3bc40fbc2d4c28c750c28';
  v_rpc_sha256 text := '46c63f7ba8a24ebbe90cea4f0216d9ea2a7219e442657fa255bf6c8345c28f81';
  v_unlink_sha256 text := '855f458797428e5b442d1a5b1ba511d96ae13b539d7ad75eea18421fd4d960cf';
  v_test_sha256 text := '475c5a6f5d4e76a852fd6d991d4343c48a202c040683cfd8d7d3a7d62f261289';
  v_schema_text text;
  v_rpc_text text;
  v_unlink_text text;
  v_test_text text;
  v_org_fp text;
  v_result text;
  v_cust_count_before bigint; v_cust_md5_before text;
  v_cust_count_after bigint; v_cust_md5_after text;
  v_prof_count_before bigint; v_prof_md5_before text;
  v_prof_count_after bigint; v_prof_md5_after text;
  v_audit_count_before bigint; v_audit_md5_before text;
  v_audit_count_after bigint; v_audit_md5_after text;
begin
  -- ── 0. lock budget -- first executed statement, before even the time gate.
  perform set_config('lock_timeout', '5s', true);

  -- ── 1. time gate ──────────────────────────────────────────────────────────────────────
  v_now_ist := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  if v_now_ist < time '11:00' then
    raise exception 'rehearsal refused: run only after 11:00 IST (Asia/Kolkata) -- current IST time is %', v_now_ist;
  end if;

  -- ── 2. organisation fingerprint pin ─────────────────────────────────────────────────────
  select md5(o.id::text || '|' || o.name) into v_org_fp
    from public.organizations o
    where o.name not like '\_\_TEST\_%' escape '\'
    order by o.created_at asc, o.id asc
    limit 1;
  if v_org_fp is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- ── 3. embedded text: schema, rpc, unlink-block migrations, test ───────────────────────
  v_schema_text := $SCHEMA_BODY$-- Schema for auto-onboarding a customer on first Google sign-in. Additive only, plus one
-- necessary relaxation (customers.mobile NOT NULL -> nullable, see below).
--
-- customers.email: NEW. Nullable, loose format check (same shape as the existing
-- customer_members.email check from 20261012110000_customer_member_email.sql). This is the ONLY
-- column customer_auto_onboard() (next migration) matches a Google sign-in's email against --
-- never customer_members.email, which is a family member's own optional email, not the account
-- holder's.
--
-- customers.needs_review / needs_review_reason: NEW. Set when auto-onboarding had to create a
-- new customer instead of linking because the email match was ambiguous (more than one existing
-- customer with that email) or because the one match it found was already linked to a different
-- Google sign-in -- never guessed at in either case. Surfaced to master/ops as a badge (frontend,
-- same migration's sibling PR).
--
-- customers.mobile: relaxed from NOT NULL to nullable. A customer created by Google
-- auto-onboarding has no phone number at all until they provide one later (spec: "Phone: DO NOT
-- match on a phone number the user typed" -- phone-based linking stays the existing OTP flow's
-- job, flag OFF). The pre-existing format check (20260819100000_customer_mobile_format_constraint.sql,
-- `mobile ~ '^\d{10}$'`) already tolerates NULL unmodified -- in Postgres, `NULL ~ pattern`
-- evaluates to NULL, and a CHECK constraint only fails on an explicit `false`, never on NULL --
-- so no change to that constraint is needed or made. Confirmed no UNIQUE constraint/index
-- involves mobile (only the non-unique `customers_mobile_idx (org_id, mobile)`), so multiple
-- NULLs in the same org are unaffected either way.
--
-- Exhaustive audit (2026-11-30, re-run after an owner challenge to the first pass) of every
-- `customers.mobile` read/write across SQL functions/views/triggers/policies, Edge Functions and
-- the TS/TSX frontend. DB-side identify/match lookups (`wa_identify_customer`, the WA outbound
-- allow-list, lead-notification identify, `_mobile_key`) are all equality comparisons against a
-- real phone -- `NULL = x` is never true, so a mobile-less customer is correctly "not found",
-- never a crash. Frontend: JSX interpolation (`{x.mobile}`) renders nothing for null, already
-- safe everywhere. Found and fixed, same PR as this migration:
--   - CustomerDetailPage.tsx's WhatsApp-link derivation (the one found in the first pass).
--   - Two WhatsApp scheduled-task sends (supabase/functions/wa-scheduled-tasks/index.ts,
--     AMC reminders + feedback requests) that guarded "no customer row" but not "no mobile" --
--     would have tried to send to a null destination for any auto-onboarded customer with an
--     AMC contract or completed ticket. Now skip when mobile is null, same as "no customer".
--   - 8 customer-picker label template literals across 6 admin pages (SellAmcPanel,
--     LeadDetailPanel, QuotationFormPage, RentOutPanel, NewComplaintPage x2, NewSalePage x3)
--     that stringified a null mobile as the literal text "null" (template-literal
--     interpolation, unlike JSX, does not render null as nothing). Now show the name alone when
--     mobile is null.
--   - The Customers CSV export's Mobile column, same "null"-the-literal-string issue.
alter table public.customers alter column mobile drop not null;

alter table public.customers add column email text;
alter table public.customers add constraint customers_email_format
  check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.customers add column needs_review boolean not null default false;
alter table public.customers add column needs_review_reason text;

-- source already has a fitting enum value for this -- lead_source.'customer_app'
-- (20260701090000_extensions_and_enums.sql) -- no new enum value or column needed; the RPC uses
-- that value verbatim for every customer it creates.

-- customers.auto_link_blocked_at / auto_link_blocked_by: NEW. Set by
-- admin_unlink_customer_google_account (redefined in 20261130100002) when a master unlinks a
-- customer's Google sign-in. Prevents the "unlink loop": without this, the very next sign-in by
-- that same Google account would hit customer_auto_onboard(), see the customer unlinked again,
-- and silently re-link it right back -- defeating the master's unlink entirely. Cleared only by
-- a master successfully re-linking the SAME customer via admin_link_customer_google_account
-- (also redefined in 20261130100002) -- an explicit master action, never automatically.
alter table public.customers add column auto_link_blocked_at timestamptz;
alter table public.customers add column auto_link_blocked_by uuid references public.profiles (id) on delete set null;
$SCHEMA_BODY$;

  v_rpc_text := $RPC_BODY$-- Auto-onboarding on first Google sign-in (customer app). Replaces the dead-end "contact the
-- shop" notice for the common case: a brand-new Google sign-in with no profiles row yet.
--
-- Trust model, same spirit as admin_link_customer_google_account (20261121100000) but fully
-- server-driven: the function takes NO identity parameters at all. Every fact it acts on --
-- the caller's own Google email, whether it's Google-verified, whether the caller already has a
-- profile -- is read server-side from auth.uid() / auth.users / auth.identities. There is
-- nothing for a malicious caller to pass in that could make this function act on anyone else's
-- record: the ONLY input is auth.uid() itself, which the caller cannot forge (it comes from
-- their own verified JWT, the same as every other `auth.uid()`-based function in this project).
--
-- Email source: auth.identities, provider = 'google', not auth.users.email -- identical
-- reasoning to admin_link_customer_google_account's own comment (that function's lookup goes the
-- other direction -- master-typed email to identity -- this one goes identity to email, but it's
-- the same "the identity row is what Google actually verified" principle). Additionally requires
-- auth.users.email_confirmed_at is not null for THIS caller -- Google sign-ins are normally
-- already confirmed by the time the session exists, but this is checked explicitly rather than
-- assumed.
--
-- Match rule (never guesses):
--   0 matches                                  -> create a new 'customer_app'-sourced customer,
--                                                  not flagged.
--   exactly 1 match, that customer unlinked     -> link (same effect as
--                                                  admin_link_customer_google_account: create the
--                                                  profiles row, set primary_profile_id).
--   exactly 1 match, already linked to a         -> DO NOT link (would silently take over someone
--     DIFFERENT auth user                          else's account). Create a new customer instead,
--                                                  flagged needs_review.
--   more than 1 match                           -> ambiguous. Create a new customer instead,
--                                                  flagged needs_review. Never pick one.
-- "Match" is always is_test = false and lower(trim(email)) exact-equality -- test customers are
-- never matched, by construction (the WHERE clause excludes them, not a post-hoc check).
--
-- Idempotent: a caller who already has ANY profiles row short-circuits immediately -- a
-- 'customer' role profile returns its already-linked customers row unchanged (no new INSERT, no
-- new audit_log row, this is a pure read on retry); any other role raises 'staff_account' and
-- touches nothing. This is also what makes a second concurrent call for the same caller safe on
-- its own merits, on top of the advisory lock below: whichever of two racing calls loses the
-- lock wait sees the first call's already-committed profiles row and takes the idempotent path.
create or replace function public.customer_auto_onboard()
returns public.customers
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_existing public.customers;
  v_email text;
  v_name text;
  v_default_org uuid;
  v_match_count int;
  v_matched public.customers;
  v_new public.customers;
  v_reason text;
begin
  if v_uid is null then
    raise exception 'customer_auto_onboard: no authenticated user';
  end if;

  -- Serializes two concurrent calls for the SAME caller (double-click, a retry racing the
  -- first attempt) -- belt-and-suspenders on top of the idempotent short-circuit above and
  -- profiles' own primary key (id = auth.uid()), which would otherwise turn a genuine race
  -- into a unique_violation instead of a clean second "already onboarded" return.
  perform pg_advisory_xact_lock(hashtext(v_uid::text));

  if exists (select 1 from public.profiles where id = v_uid) then
    if exists (select 1 from public.profiles where id = v_uid and role is distinct from 'customer') then
      raise exception 'staff_account';
    end if;
    select c.* into v_existing from public.customers c where c.primary_profile_id = v_uid;
    if v_existing.id is not null then
      return v_existing;
    end if;
    -- a customer-role profile with no linked customer row should never happen through any path
    -- this project has today (every customer-role profile is created either by
    -- admin_link_customer_google_account, this function, or OTP linking -- all three set
    -- primary_profile_id in the same transaction as the profiles insert) -- refuse rather than
    -- guess if it somehow does.
    raise exception 'customer_auto_onboard: profile exists with no linked customer';
  end if;

  select lower(trim(i.identity_data->>'email')) into v_email
    from auth.identities i
   where i.user_id = v_uid and i.provider = 'google'
   order by i.created_at asc
   limit 1;

  if v_email is null or v_email = '' then
    raise exception 'customer_auto_onboard: no Google sign-in found for this user';
  end if;

  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    raise exception 'customer_auto_onboard: email not confirmed';
  end if;

  -- Supabase's Google provider has populated this under slightly different keys across
  -- versions (full_name, name) -- try both, falling back to the identities row (which is
  -- always present here, already fetched above) before giving up to a generic label.
  select coalesce(
    nullif(btrim(u.raw_user_meta_data->>'full_name'), ''),
    nullif(btrim(u.raw_user_meta_data->>'name'), ''),
    nullif(btrim(i.identity_data->>'full_name'), ''),
    nullif(btrim(i.identity_data->>'name'), '')
  ) into v_name
  from auth.users u
  left join auth.identities i on i.user_id = u.id and i.provider = 'google'
  where u.id = v_uid
  order by i.created_at asc
  limit 1;

  -- The one real (non-__TEST_) organisation -- same convention this project's own
  -- rehearsal/apply scripts already pin on (oldest real org by created_at). A brand-new Google
  -- sign-in has no org context of its own to draw from (no profile yet), so this is the only
  -- place that context can come from.
  select o.id into v_default_org
    from public.organizations o
   where o.name not like '\_\_TEST\_%' escape '\'
   order by o.created_at asc
   limit 1;

  if v_default_org is null then
    raise exception 'customer_auto_onboard: no organisation to onboard into';
  end if;

  -- SECURITY REVIEW (2026-11-30) -- accepted single-org limitation, documented not fixed: this
  -- match (and v_matched below) is NOT scoped to v_default_org or any org at all -- it searches
  -- every organisation. Harmless today because v_default_org IS the only real organisation
  -- (same premise this whole function's org-selection already depends on), but if a second
  -- real organisation is ever created, a sign-in intended for org B could match and link to a
  -- customer that actually belongs to org A, with no client-supplied org to validate against
  -- (this function has no parameters at all, so there is nothing to scope the match TO until
  -- after it already ran). Revisit before this project is ever multi-org: either scope both
  -- queries to v_default_org, or add a loud guard that refuses outright if more than one real
  -- organisation exists.
  select count(*) into v_match_count
    from public.customers c
   where c.is_test = false
     and c.email is not null
     and lower(trim(c.email)) = v_email;

  if v_match_count = 1 then
    -- FOR UPDATE: closes the race between two DIFFERENT callers whose emails both match this
    -- same unlinked customer at the same time (admin_link_customer_google_account locks its
    -- matched row the same way, for the same reason) -- without it, both could read
    -- primary_profile_id IS NULL before either writes, and both would try to link.
    select c.* into v_matched
      from public.customers c
     where c.is_test = false
       and c.email is not null
       and lower(trim(c.email)) = v_email
     limit 1
     for update;

    if v_matched.primary_profile_id is null and v_matched.auto_link_blocked_at is null then
      -- Link: same data effects as admin_link_customer_google_account's own link path.
      insert into public.profiles (id, org_id, full_name, phone, role, language)
      values (v_uid, v_matched.org_id, coalesce(nullif(v_matched.name, ''), 'Customer'), v_matched.mobile, 'customer', coalesce(v_matched.preferred_language, 'en'));

      update public.customers set primary_profile_id = v_uid where id = v_matched.id;

      insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
      values (
        v_matched.org_id, null, 'auto_link_email', 'customers', v_matched.id,
        jsonb_build_object('primary_profile_id', null),
        jsonb_build_object('primary_profile_id', v_uid, 'google_email', v_email)
      );

      select c.* into v_existing from public.customers c where c.id = v_matched.id;
      return v_existing;
    end if;

    -- Exactly one match, but either (a) it's already linked to a DIFFERENT auth user -- never
    -- take over an existing login, or (b) a master deliberately unlinked it and it's still
    -- blocked -- never silently re-link what a master just undid. Either way, falls through to
    -- the create-new-flagged path below.
    if v_matched.auto_link_blocked_at is not null then
      v_reason := 'email matched a customer a master unlinked -- blocked from auto-relinking until a master relinks it';
    else
      v_reason := 'email matched an existing customer already linked to a different sign-in';
    end if;
  elsif v_match_count > 1 then
    -- Ambiguous -- more than one existing customer shares this email. Never pick one.
    v_reason := 'email matched more than one existing customer';
  end if;
  -- v_match_count = 0 falls through with v_reason still null (not flagged).

  -- profiles row MUST be inserted first -- customers.primary_profile_id is a foreign key to it,
  -- so referencing v_uid in the customers insert before this would violate that constraint.
  insert into public.profiles (id, org_id, full_name, phone, role, language)
  values (v_uid, v_default_org, coalesce(v_name, 'Customer'), null, 'customer', 'en');

  insert into public.customers (org_id, name, mobile, email, source, is_test, needs_review, needs_review_reason, primary_profile_id)
  values (
    v_default_org, coalesce(v_name, 'Customer'), null, v_email, 'customer_app', false,
    v_reason is not null, v_reason, v_uid
  )
  returning * into v_new;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_default_org, null, 'auto_create', 'customers', v_new.id,
    null,
    jsonb_build_object('email', v_email, 'needs_review', v_new.needs_review, 'needs_review_reason', v_reason)
  );

  return v_new;
end;
$$;

revoke all on function public.customer_auto_onboard() from public, anon, authenticated;
grant execute on function public.customer_auto_onboard() to authenticated;
$RPC_BODY$;

  v_unlink_text := $UNLINK_BODY$-- Closes the "unlink loop": without this, a master's admin_unlink_customer_google_account
-- (20261121100000, already live) clears customers.primary_profile_id, and the very next time
-- that same Google account signs in, customer_auto_onboard() (20261130100001, this branch) sees
-- an unlinked customer with a matching email and silently re-links it right back -- undoing the
-- master's unlink entirely, with no way to make it stick.
--
-- customers.auto_link_blocked_at / auto_link_blocked_by (added in 20261130100000, this branch)
-- is the fix: admin_unlink_customer_google_account now sets both on every successful unlink;
-- customer_auto_onboard() already refuses to auto-link a customer with auto_link_blocked_at set
-- (see that migration). The block is cleared ONLY by a master explicitly relinking via
-- admin_link_customer_google_account -- an auto-onboard call never clears it, by construction
-- (it only ever sets primary_profile_id on the UNBLOCKED path).
--
-- Both functions below are reproduced from their live 20261121100000 bodies, each with exactly
-- one line changed (the final UPDATE on customers) plus this comment -- everything else is
-- byte-for-byte the live definition, confirmed by diff against 20261121100000_admin_link_customer_google_account.sql
-- in this same worktree before this migration was written.
create or replace function public.admin_link_customer_google_account(p_customer_id uuid, p_google_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(p_google_email));
  v_customer record;
  v_auth_id uuid;
  v_match_count int;
begin
  if auth.uid() is null then
    raise exception 'admin_link_customer_google_account: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_link_customer_google_account: master role required';
  end if;
  if v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  select id, org_id, name, mobile, preferred_language, primary_profile_id, is_test
    into v_customer
    from public.customers
   where id = p_customer_id
     for update;

  if v_customer.id is null or v_customer.org_id is distinct from public.current_org_id() then
    raise exception 'customer_not_found';
  end if;
  if v_customer.is_test then
    raise exception 'test_customer';
  end if;
  if v_customer.primary_profile_id is not null then
    raise exception 'already_linked';
  end if;

  select count(*) into v_match_count
    from auth.identities i
   where i.provider = 'google'
     and lower(trim(i.identity_data->>'email')) = v_email;

  if v_match_count = 0 then
    raise exception 'no_matching_signin';
  end if;
  if v_match_count > 1 then
    raise exception 'ambiguous_signin';
  end if;

  select i.user_id into v_auth_id
    from auth.identities i
   where i.provider = 'google'
     and lower(trim(i.identity_data->>'email')) = v_email;

  if exists (select 1 from public.profiles where id = v_auth_id) then
    raise exception 'signin_already_linked';
  end if;

  begin
    insert into public.profiles (id, org_id, full_name, phone, role, language)
    values (v_auth_id, v_customer.org_id, coalesce(nullif(v_customer.name, ''), 'Customer'), v_customer.mobile, 'customer', coalesce(v_customer.preferred_language, 'en'));
  exception when unique_violation then
    raise exception 'signin_already_linked';
  end;

  -- CHANGED (this migration): also clears any auto-link block -- a master explicitly linking
  -- this customer is exactly the "cleared only by a master relink" action the block exists to
  -- wait for.
  update public.customers set primary_profile_id = v_auth_id, auto_link_blocked_at = null, auto_link_blocked_by = null where id = v_customer.id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_customer.org_id, auth.uid(), 'admin_link_google_account', 'customers', v_customer.id,
    jsonb_build_object('primary_profile_id', null),
    jsonb_build_object('primary_profile_id', v_auth_id, 'google_email', v_email)
  );
end;
$$;

revoke all on function public.admin_link_customer_google_account(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_link_customer_google_account(uuid, text) to authenticated;

create or replace function public.admin_unlink_customer_google_account(p_customer_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_customer record;
  v_profile_id uuid;
begin
  if auth.uid() is null then
    raise exception 'admin_unlink_customer_google_account: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_unlink_customer_google_account: master role required';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'reason_required';
  end if;

  select id, org_id, primary_profile_id
    into v_customer
    from public.customers
   where id = p_customer_id
     for update;

  if v_customer.id is null or v_customer.org_id is distinct from public.current_org_id() then
    raise exception 'customer_not_found';
  end if;
  if v_customer.primary_profile_id is null then
    raise exception 'not_linked';
  end if;

  v_profile_id := v_customer.primary_profile_id;

  -- CHANGED (this migration): also sets the auto-link block, so customer_auto_onboard() will
  -- not silently re-link this customer the next time this same Google account signs in.
  update public.customers set primary_profile_id = null, auto_link_blocked_at = now(), auto_link_blocked_by = auth.uid() where id = v_customer.id;

  begin
    delete from public.profiles where id = v_profile_id;
  exception when foreign_key_violation then
    raise exception 'unlink_blocked_has_records';
  end;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_customer.org_id, auth.uid(), 'admin_unlink_google_account', 'customers', v_customer.id,
    jsonb_build_object('primary_profile_id', v_profile_id),
    jsonb_build_object('primary_profile_id', null, 'reason', p_reason, 'auto_link_blocked', true)
  );
end;
$$;

revoke all on function public.admin_unlink_customer_google_account(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_unlink_customer_google_account(uuid, text) to authenticated;
$UNLINK_BODY$;

  v_test_text := $TEST_BODY$-- Rolled-back DB tests for 20261130100000_customer_auto_onboard_schema.sql +
-- 20261130100001_customer_auto_onboard_rpc.sql. Run through the Management API (database/
-- query); always ends in a RAISE so nothing persists. Read RESULTS in the error. Creates its own
-- __TEST_ organisation, users, customers and throwaway auth.identities (provider='google') rows
-- per scenario -- never reads from or depends on whatever real data already exists, other than a
-- final real-row-count sanity check.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- pg_temp functions are not executable by `authenticated` by default -- this test switches role
-- via pg_temp.as_user() before calling pg_temp.chk() inside that switched context, so this grant
-- is required (same fix as admin_link_customer_google_account.test.sql's own header note).
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
-- A Google sign-in with no profile yet. p_confirmed controls email_confirmed_at (scenario 8
-- needs an UNCONFIRMED one); p_name feeds raw_user_meta_data.full_name (what the RPC reads for
-- a newly-created customer's name).
create function pg_temp.mkgoogle(p_email text, p_confirmed boolean default true, p_name text default 'Onboard Test') returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (
    v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_google_' || v || '@test.invalid', 'x',
    case when p_confirmed then now() else null end, now(), now(), '{}',
    jsonb_build_object('full_name', p_name)
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v, v::text, 'google', jsonb_build_object('sub', v::text, 'email', p_email, 'full_name', p_name, 'email_verified', p_confirmed), now(), now(), now());
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid;
  c_unlinked uuid; c_test uuid; c_linked_elsewhere uuid; c_dup_a uuid; c_dup_b uuid;
  g_new uuid; g_match_unlinked uuid; g_match_test uuid; g_already_elsewhere uuid; g_ambiguous uuid;
  g_unconfirmed uuid; g_staff_own uuid;
  v_result public.customers;
  v_result2 public.customers;
  v_audit record;
  v_n int;
  rc_before bigint; pc_before bigint; ac_before bigint;
  rc_after bigint; pc_after bigint; ac_after bigint;
begin
  select count(*) into rc_before from public.customers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into pc_before from public.profiles where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into ac_before from public.audit_log where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  -- Security proof: the function takes NO parameters at all -- mechanical, not just read-by-eye.
  perform pg_temp.chk('customer_auto_onboard() takes zero arguments',
    pg_get_function_arguments('public.customer_auto_onboard()'::regprocedure) = '');

  -- Grants.
  perform pg_temp.chk('anon cannot execute customer_auto_onboard',
    not has_function_privilege('anon', 'public.customer_auto_onboard()', 'EXECUTE'));
  perform pg_temp.chk('authenticated can execute customer_auto_onboard',
    has_function_privilege('authenticated', 'public.customer_auto_onboard()', 'EXECUTE'));

  insert into public.organizations (name) values ('__TEST_auto_onboard') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);

  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ unlinked', '9500000101', 'onboard.unlinked.test@gmail.com') returning id into c_unlinked;
  insert into public.customers (org_id, name, mobile, email, is_test) values (v_org, '__TEST_ istest', '9500000102', 'onboard.test.test@gmail.com', true) returning id into c_test;
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ linked_elsewhere', '9500000103', 'onboard.elsewhere.test@gmail.com') returning id into c_linked_elsewhere;
  update public.customers set primary_profile_id = v_ops where id = c_linked_elsewhere; -- "linked to a different auth user" (v_ops's own profile)
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ dup a', '9500000104', 'onboard.ambiguous.test@gmail.com') returning id into c_dup_a;
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ dup b', '9500000105', 'onboard.ambiguous.test@gmail.com') returning id into c_dup_b;

  -- ===== 1. staff_account: a staff/master auth user is refused, nothing changes =====
  perform pg_temp.as_user(v_master);
  begin
    perform public.customer_auto_onboard();
    perform pg_temp.chk('staff auth user refused', false);
  exception when others then
    perform pg_temp.chk('staff auth user refused', sqlerrm like '%staff_account%', sqlerrm);
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff profile untouched by the refused call',
    (select role from public.profiles where id = v_master) = 'master');

  -- ===== 2. unconfirmed email: refused, no link, no create =====
  g_unconfirmed := pg_temp.mkgoogle('onboard.unconfirmed.test@gmail.com', false);
  perform pg_temp.as_user(g_unconfirmed);
  begin
    perform public.customer_auto_onboard();
    perform pg_temp.chk('unconfirmed-email sign-in refused', false);
  exception when others then
    perform pg_temp.chk('unconfirmed-email sign-in refused', sqlerrm like '%email not confirmed%', sqlerrm);
  end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('no profile created for the unconfirmed sign-in',
    not exists (select 1 from public.profiles where id = g_unconfirmed));

  -- ===== 3. test customers are never matched: a matching email on an is_test customer creates
  --          a NEW customer instead of linking to the test one =====
  g_match_test := pg_temp.mkgoogle('onboard.test.test@gmail.com');
  perform pg_temp.as_user(g_match_test);
  v_result := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('test customer never matched: a new customer was created, not the test one',
    v_result.id is distinct from c_test and v_result.email = 'onboard.test.test@gmail.com');
  perform pg_temp.chk('new customer from a test-email-collision is not itself flagged (0 real matches)',
    v_result.needs_review = false);
  perform pg_temp.chk('the test customer itself stays unlinked', (select primary_profile_id from public.customers where id = c_test) is null);

  -- ===== 4. zero matches: a brand-new email creates a new, unflagged 'customer_app' customer =====
  g_new := pg_temp.mkgoogle('onboard.new.test@gmail.com', true, 'Brand New Customer');
  perform pg_temp.as_user(g_new);
  v_result := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('zero-match create: source is customer_app', v_result.source = 'customer_app');
  perform pg_temp.chk('zero-match create: not flagged', v_result.needs_review = false and v_result.needs_review_reason is null);
  perform pg_temp.chk('zero-match create: not a test customer', v_result.is_test = false);
  perform pg_temp.chk('zero-match create: mobile is null (never a typed/guessed phone)', v_result.mobile is null);
  perform pg_temp.chk('zero-match create: name from the Google profile', v_result.name = 'Brand New Customer');
  perform pg_temp.chk('zero-match create: linked to the new auth user', v_result.primary_profile_id = g_new);
  select * into v_audit from public.audit_log where table_name = 'customers' and row_id = v_result.id and action = 'auto_create' order by created_at desc limit 1;
  perform pg_temp.chk('zero-match create: audit row written', v_audit.id is not null);

  -- ===== 5. idempotent: calling again for the SAME auth user returns the same row, no new writes =====
  perform pg_temp.as_user(g_new);
  v_result2 := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('idempotent re-call returns the same customer id', v_result2.id = v_result.id);
  select count(*) into v_n from public.audit_log where table_name = 'customers' and row_id = v_result.id and action = 'auto_create';
  perform pg_temp.chk('idempotent re-call wrote no second audit row', v_n = 1, v_n::text);

  -- ===== 6. one unlinked match: links (same effect as admin_link_customer_google_account) =====
  g_match_unlinked := pg_temp.mkgoogle('onboard.unlinked.test@gmail.com');
  perform pg_temp.as_user(g_match_unlinked);
  v_result := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('single unlinked match: links to the existing customer', v_result.id = c_unlinked);
  perform pg_temp.chk('single unlinked match: primary_profile_id set to the new auth user', v_result.primary_profile_id = g_match_unlinked);
  perform pg_temp.chk('single unlinked match: not flagged', v_result.needs_review = false);
  select * into v_audit from public.audit_log where table_name = 'customers' and row_id = c_unlinked and action = 'auto_link_email' order by created_at desc limit 1;
  perform pg_temp.chk('single unlinked match: audit row written', v_audit.id is not null);

  -- ===== 7. one match, already linked to a DIFFERENT auth user: never takes over, creates a
  --          new FLAGGED customer instead =====
  g_already_elsewhere := pg_temp.mkgoogle('onboard.elsewhere.test@gmail.com');
  perform pg_temp.as_user(g_already_elsewhere);
  v_result := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('already-linked-elsewhere match: did NOT link to the existing customer', v_result.id is distinct from c_linked_elsewhere);
  perform pg_temp.chk('already-linked-elsewhere match: flagged for review', v_result.needs_review = true and v_result.needs_review_reason is not null);
  perform pg_temp.chk('already-linked-elsewhere: the existing customer''s link is untouched',
    (select primary_profile_id from public.customers where id = c_linked_elsewhere) = v_ops);

  -- ===== 8. more than one match (ambiguous): never picks one, creates a new FLAGGED customer =====
  g_ambiguous := pg_temp.mkgoogle('onboard.ambiguous.test@gmail.com');
  perform pg_temp.as_user(g_ambiguous);
  v_result := public.customer_auto_onboard();
  perform pg_temp.as_pg();
  perform pg_temp.chk('ambiguous match: did not link to either existing customer',
    v_result.id is distinct from c_dup_a and v_result.id is distinct from c_dup_b);
  perform pg_temp.chk('ambiguous match: flagged for review', v_result.needs_review = true and v_result.needs_review_reason is not null);
  perform pg_temp.chk('ambiguous match: neither existing customer was touched',
    (select primary_profile_id from public.customers where id = c_dup_a) is null
    and (select primary_profile_id from public.customers where id = c_dup_b) is null);

  -- ===== 9. a staff/technician's own account can never be auto-onboarded as a customer -- the
  --          refusal happens on "this auth user already has a profile", before the function
  --          ever looks at an email, so it holds regardless of what that email is =====
  g_staff_own := pg_temp.mkuser('technician', v_org);
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), g_staff_own, g_staff_own::text, 'google', jsonb_build_object('sub', g_staff_own::text, 'email', 'onboard.staffown.test@gmail.com', 'email_verified', true), now(), now(), now());
  perform pg_temp.as_user(g_staff_own);
  begin
    perform public.customer_auto_onboard();
    perform pg_temp.chk('a technician''s own Google identity is refused, not onboarded as a customer', false);
  exception when others then
    perform pg_temp.chk('a technician''s own Google identity is refused, not onboarded as a customer', sqlerrm like '%staff_account%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ===== 10. unlink loop: a master unlinking a customer must NOT be silently undone by the
  --           next sign-in auto-relinking it (20261130100002) =====
  declare
    c_block1 uuid; g_block1 uuid; v_block_result public.customers;
  begin
    insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ block1', '9500000106', 'onboard.block1.test@gmail.com') returning id into c_block1;
    g_block1 := pg_temp.mkgoogle('onboard.block1.test@gmail.com');

    perform pg_temp.as_user(g_block1);
    v_block_result := public.customer_auto_onboard();
    perform pg_temp.as_pg();
    perform pg_temp.chk('unlink-loop setup: auto-onboard linked to c_block1', v_block_result.id = c_block1);

    perform pg_temp.as_user(v_master);
    perform public.admin_unlink_customer_google_account(c_block1, 'testing the unlink loop');
    perform pg_temp.as_pg();
    perform pg_temp.chk('unlink sets auto_link_blocked_at/by', (select auto_link_blocked_at from public.customers where id = c_block1) is not null and (select auto_link_blocked_by from public.customers where id = c_block1) = v_master);
    perform pg_temp.chk('unlink cleared primary_profile_id', (select primary_profile_id from public.customers where id = c_block1) is null);

    -- g_block1 has no profile again (admin_unlink deletes it) -- signing in again must NOT
    -- re-link to c_block1. It must create a new, independent, flagged customer instead.
    perform pg_temp.as_user(g_block1);
    v_block_result := public.customer_auto_onboard();
    perform pg_temp.as_pg();
    perform pg_temp.chk('blocked customer is NOT silently re-linked on the next sign-in', v_block_result.id is distinct from c_block1);
    perform pg_temp.chk('the next sign-in instead creates a flagged new customer', v_block_result.needs_review = true and v_block_result.needs_review_reason like '%blocked%');
    perform pg_temp.chk('the blocked customer itself is untouched (still unlinked, still blocked)',
      (select primary_profile_id from public.customers where id = c_block1) is null
      and (select auto_link_blocked_at from public.customers where id = c_block1) is not null);
  end;

  -- ===== 11. unlink loop: the block is cleared ONLY by a master explicitly relinking =====
  declare
    c_block2 uuid; g_block2 uuid;
  begin
    insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ block2', '9500000107', 'onboard.block2.test@gmail.com') returning id into c_block2;
    g_block2 := pg_temp.mkgoogle('onboard.block2.test@gmail.com');

    perform pg_temp.as_user(v_master);
    perform public.admin_link_customer_google_account(c_block2, 'onboard.block2.test@gmail.com');
    perform public.admin_unlink_customer_google_account(c_block2, 'testing relink clears the block');
    perform pg_temp.chk('setup: c_block2 is unlinked and blocked',
      (select primary_profile_id from public.customers where id = c_block2) is null
      and (select auto_link_blocked_at from public.customers where id = c_block2) is not null);

    -- g_block2 has no profile again (the unlink above deleted it) -- a master can relink it.
    perform public.admin_link_customer_google_account(c_block2, 'onboard.block2.test@gmail.com');
    perform pg_temp.as_pg();
    perform pg_temp.chk('master relink clears the auto-link block',
      (select auto_link_blocked_at from public.customers where id = c_block2) is null
      and (select auto_link_blocked_by from public.customers where id = c_block2) is null);
    perform pg_temp.chk('master relink re-sets primary_profile_id', (select primary_profile_id from public.customers where id = c_block2) = g_block2);
  end;

  -- ===== real-data safety net (redundant with the wrapper-level fingerprint, belt and braces) =====
  select count(*) into rc_after from public.customers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into pc_after from public.profiles where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into ac_after from public.audit_log where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real customers row count unchanged', rc_before = rc_after, format('%s -> %s', rc_before, rc_after));
  perform pg_temp.chk('real profiles row count unchanged', pc_before = pc_after, format('%s -> %s', pc_before, pc_after));
  perform pg_temp.chk('real audit_log row count unchanged', ac_before = ac_after, format('%s -> %s', ac_before, ac_after));

  raise exception E'RESULTS\n%', (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
$TEST_BODY$;

  if encode(sha256(convert_to(v_schema_text, 'UTF8')), 'hex') <> v_schema_sha256 then
    raise exception 'schema migration hash mismatch: expected %, got %', v_schema_sha256, encode(sha256(convert_to(v_schema_text, 'UTF8')), 'hex');
  end if;
  if encode(sha256(convert_to(v_rpc_text, 'UTF8')), 'hex') <> v_rpc_sha256 then
    raise exception 'rpc migration hash mismatch: expected %, got %', v_rpc_sha256, encode(sha256(convert_to(v_rpc_text, 'UTF8')), 'hex');
  end if;
  if encode(sha256(convert_to(v_unlink_text, 'UTF8')), 'hex') <> v_unlink_sha256 then
    raise exception 'unlink-block migration hash mismatch: expected %, got %', v_unlink_sha256, encode(sha256(convert_to(v_unlink_text, 'UTF8')), 'hex');
  end if;
  if encode(sha256(convert_to(v_test_text, 'UTF8')), 'hex') <> v_test_sha256 then
    raise exception 'test hash mismatch: expected %, got %', v_test_sha256, encode(sha256(convert_to(v_test_text, 'UTF8')), 'hex');
  end if;

  -- ── 4. real-org fingerprint (BEFORE), outside the __TEST_ organisations the embedded test
  --      creates for itself ───────────────────────────────────────────────────────────────
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_before, v_cust_md5_before
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_prof_count_before, v_prof_md5_before
  from public.profiles
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_audit_count_before, v_audit_md5_before
  from public.audit_log
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  -- ── 5. run: schema, then rpc, then unlink-block, then the test (true apply order) ──────
  execute v_schema_text;
  execute v_rpc_text;
  execute v_unlink_text;

  begin
    execute v_test_text;
    v_result := 'RESULTS(test did not raise -- unexpected, treat as FAIL)';
  exception when others then
    v_result := sqlerrm;
  end;

  -- ── 6. real-org fingerprint (AFTER) ─────────────────────────────────────────────────────
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_after, v_cust_md5_after
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_prof_count_after, v_prof_md5_after
  from public.profiles
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_audit_count_after, v_audit_md5_after
  from public.audit_log
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  raise exception E'wrapper-level real-org fingerprint -- customers: count before=% after=% (match=%) md5 before=% after=% (match=%); profiles: count before=% after=% (match=%) md5 before=% after=% (match=%); audit_log: count before=% after=% (match=%) md5 before=% after=% (match=%)\n%',
    v_cust_count_before, v_cust_count_after, (v_cust_count_before = v_cust_count_after),
    v_cust_md5_before, v_cust_md5_after, (v_cust_md5_before = v_cust_md5_after),
    v_prof_count_before, v_prof_count_after, (v_prof_count_before = v_prof_count_after),
    v_prof_md5_before, v_prof_md5_after, (v_prof_md5_before = v_prof_md5_after),
    v_audit_count_before, v_audit_count_after, (v_audit_count_before = v_audit_count_after),
    v_audit_md5_before, v_audit_md5_after, (v_audit_md5_before = v_audit_md5_after),
    v_result;
end
$rehearsal$;
