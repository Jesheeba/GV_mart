-- GO APPLY script for 20261130100000_customer_auto_onboard_schema.sql THEN
-- 20261130100001_customer_auto_onboard_rpc.sql (customer auto-onboarding on first Google sign-in:
-- 3 new nullable customer columns, 1 NOT NULL relaxation, 1 brand-new SECURITY DEFINER function),
-- branch feat/customer-auto-onboard.
--
-- WRITTEN against the approved template (supabase/ops/20261108100000_customer_water_profile.apply.sql,
-- also used by 20261121100000_admin_link_customer_google_account.apply.sql). The owner runs or
-- authorizes this after 11:00 IST, once satisfied the sha256-pinned migration text embedded
-- below is byte-for-byte the reviewed migration files (schema
-- d86363e68b78fbc304c66dc3d36cfc2dd553d51651dd19527c9684e4c8e6b336, rpc
-- 6b977978cffd255bb62d856cb29b67c53c2cc7becd7334e7ce30a8b542b2bab3), that the DRYRUN copy of THIS
-- SAME apply script came back clean against live data, and that the live rehearsal of both
-- migrations + the test file came back clean (it did -- 28/28 PASS, independently re-verified
-- twice in separate requests that nothing persisted).
--
-- UPDATE/BACKFILL: NONE for any existing row. customers.email / needs_review /
-- needs_review_reason are new, nullable/defaulted columns -- every existing row gets NULL /
-- false, which is exactly the correct "not auto-onboarded" state for a row that predates this
-- feature. customers.mobile NOT NULL -> nullable touches no existing row's value, only what
-- future inserts are allowed to omit -- the pre-existing format CHECK (`mobile ~ '^\d{10}$'`)
-- already silently permits NULL (a CHECK is satisfied when its expression evaluates to NULL),
-- so no CHECK change is made or needed.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. GATE             -- refuses before 11:00 IST.
--   3. ALREADY-REGISTERED CHECK -- refuses if EITHER version (20261130100000 / 20261130100001)
--                           is already registered.
--   4. NEW-OBJECT PRE-CHECK -- customers.email/needs_review/needs_review_reason must not already
--                           exist; customer_auto_onboard() must not already exist;
--                           customers.mobile must currently be NOT NULL (sanity check that this
--                           hasn't already been relaxed by something else).
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers,
--                           profiles, audit_log, over REAL organisations only -- the exact
--                           formula the rehearsal used.
--   6. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
--   7. PIN              -- CR-tolerant sha256 of both embedded migration texts must equal their
--                           pinned hashes.
--   8. RUN              -- EXECUTE the schema migration, then the rpc migration, verbatim
--                           (CR-tolerant), in that order.
--   9. REGISTER         -- INSERT both version rows into supabase_migrations.schema_migrations,
--                           in the same transaction as the migrations themselves.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. the 3 new columns and the new function all exist; customers.mobile is now nullable;
--      10b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff
--          it against the BEFORE snapshot;
--      10c. ABSOLUTE check -- anon/PUBLIC cannot execute customer_auto_onboard(), independent of
--          10b;
--      10d. the real customers/profiles/audit_log fingerprints are all unchanged from step 5 --
--          this migration pair touches no existing row's data.
--   11. On success, INSERT the one status row into pg_temp.customer_auto_onboard_apply_status.
--
-- No test file is embedded here (the rehearsal already ran it live, separately, against a
-- throwaway transaction) and there is no rollback invoked automatically -- any rollback for
-- either migration is run by hand, outside this script, only if the owner decides afterwards to
-- undo the change (see supabase/rollbacks/ for the companion rollback script).

drop table if exists pg_temp.customer_auto_onboard_apply_status;
create temp table customer_auto_onboard_apply_status (
  schema_version                  text,
  rpc_version                     text,
  both_versions_registered        boolean,
  new_objects_exist                boolean,
  mobile_is_nullable               boolean,
  functions_executable_by_anon     boolean,
  newly_leaked_functions           text[],
  customers_fingerprint_unchanged  boolean,
  profiles_fingerprint_unchanged   boolean,
  audit_log_fingerprint_unchanged  boolean,
  applied_at                       timestamptz
);

do $apply$
declare
  v_ist_hour                  int;
  v_expected_org_fingerprint  text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint           text;
  v_expected_schema_hash      text := 'd86363e68b78fbc304c66dc3d36cfc2dd553d51651dd19527c9684e4c8e6b336';
  v_expected_rpc_hash         text := '6b977978cffd255bb62d856cb29b67c53c2cc7becd7334e7ce30a8b542b2bab3';
  v_actual_schema_hash        text;
  v_actual_rpc_hash           text;
  v_schema_version            text := '20261130100000';
  v_rpc_version                text := '20261130100001';
  v_already_registered        boolean;
  v_new_objects_exist          boolean := true;
  v_mobile_nullable            boolean := false;
  v_anon_exec                  boolean := false;
  v_leaked_before              text[];
  v_leaked_after               text[];
  v_newly_leaked               text[];
  v_cust_count_before bigint; v_cust_md5_before text;
  v_cust_count_after bigint; v_cust_md5_after text;
  v_prof_count_before bigint; v_prof_md5_before text;
  v_prof_count_after bigint; v_prof_md5_after text;
  v_audit_count_before bigint; v_audit_md5_before text;
  v_audit_count_after bigint; v_audit_md5_after text;
  v_embedded_schema text := $schemamig$-- Schema for auto-onboarding a customer on first Google sign-in. Additive only, plus one
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
-- so no change to that constraint is needed or made. Audited every `.mobile` call site in src/
-- for a null-unsafe access: exactly one found (CustomerDetailPage.tsx's WhatsApp link), fixed in
-- the same PR as this migration.
alter table public.customers alter column mobile drop not null;

alter table public.customers add column email text;
alter table public.customers add constraint customers_email_format
  check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.customers add column needs_review boolean not null default false;
alter table public.customers add column needs_review_reason text;

-- source already has a fitting enum value for this -- lead_source.'customer_app'
-- (20260701090000_extensions_and_enums.sql) -- no new enum value or column needed; the RPC uses
-- that value verbatim for every customer it creates.
$schemamig$;
  v_embedded_rpc text := $rpcmig$-- Auto-onboarding on first Google sign-in (customer app). Replaces the dead-end "contact the
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

    if v_matched.primary_profile_id is null then
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

    -- Exactly one match, but it's already linked to a DIFFERENT auth user -- never take over an
    -- existing login. Falls through to the create-new-flagged path below.
    v_reason := 'email matched an existing customer already linked to a different sign-in';
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
$rpcmig$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;
  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(select 1 from supabase_migrations.schema_migrations where version in (v_schema_version, v_rpc_version)) into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: % or % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied', v_schema_version, v_rpc_version;
  end if;

  -- 4. NEW-OBJECT PRE-CHECK
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name in ('email', 'needs_review', 'needs_review_reason')) then
    raise exception 'APPLY_REFUSED: one of customers.email/needs_review/needs_review_reason already exists live before this migration ran';
  end if;
  if to_regprocedure('public.customer_auto_onboard()') is not null then
    raise exception 'APPLY_REFUSED: public.customer_auto_onboard() already exists live before this migration ran';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'mobile' and is_nullable = 'NO') then
    raise exception 'APPLY_REFUSED: customers.mobile is not currently NOT NULL as expected -- something else already changed it';
  end if;

  -- 5. REAL-TABLE FINGERPRINT (BEFORE)
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

  -- 6. LEAK SNAPSHOT (BEFORE)
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

  -- 7. PIN
  v_actual_schema_hash := encode(sha256(convert_to(replace(v_embedded_schema, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_schema_hash is distinct from v_expected_schema_hash then
    raise exception 'APPLY_REFUSED: embedded schema migration text does not match its pinned sha256 (expected %, got %)', v_expected_schema_hash, v_actual_schema_hash;
  end if;
  v_actual_rpc_hash := encode(sha256(convert_to(replace(v_embedded_rpc, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_rpc_hash is distinct from v_expected_rpc_hash then
    raise exception 'APPLY_REFUSED: embedded rpc migration text does not match its pinned sha256 (expected %, got %)', v_expected_rpc_hash, v_actual_rpc_hash;
  end if;

  -- 8. RUN -- schema first, then rpc (true dependency order: the rpc references the new columns).
  execute replace(v_embedded_schema, E'\r', '');
  execute replace(v_embedded_rpc, E'\r', '');

  -- 9. REGISTER -- both versions, same transaction as the migrations themselves.
  insert into supabase_migrations.schema_migrations (version, name, statements) values
    (v_schema_version, 'customer_auto_onboard_schema', array[replace(v_embedded_schema, E'\r', '')]),
    (v_rpc_version, 'customer_auto_onboard_rpc', array[replace(v_embedded_rpc, E'\r', '')]);

  -- 10a. new objects exist; mobile is now nullable.
  v_new_objects_exist :=
    (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'email'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'needs_review'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'needs_review_reason'))
    and (to_regprocedure('public.customer_auto_onboard()') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or more new columns/the new function are missing after the migrations ran';
  end if;

  select (is_nullable = 'YES') into v_mobile_nullable
  from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'mobile';
  if not coalesce(v_mobile_nullable, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customers.mobile is still NOT NULL after the schema migration ran';
  end if;

  -- 10b. DIFF-BASED leak check.
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %', array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 10c. ABSOLUTE check.
  if has_function_privilege('anon', 'public.customer_auto_onboard()', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_auto_onboard() is executable by anon/PUBLIC';
  end if;

  -- 10d. real fingerprints unchanged.
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

  if v_cust_count_after is distinct from v_cust_count_before or v_cust_md5_after is distinct from v_cust_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real customers fingerprint changed (count before % after %, md5 before % after %)', v_cust_count_before, v_cust_count_after, v_cust_md5_before, v_cust_md5_after;
  end if;
  if v_prof_count_after is distinct from v_prof_count_before or v_prof_md5_after is distinct from v_prof_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real profiles fingerprint changed (count before % after %, md5 before % after %)', v_prof_count_before, v_prof_count_after, v_prof_md5_before, v_prof_md5_after;
  end if;
  if v_audit_count_after is distinct from v_audit_count_before or v_audit_md5_after is distinct from v_audit_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real audit_log fingerprint changed (count before % after %, md5 before % after %)', v_audit_count_before, v_audit_count_after, v_audit_md5_before, v_audit_md5_after;
  end if;

  -- 11. Every step above passed.
  insert into pg_temp.customer_auto_onboard_apply_status (
    schema_version, rpc_version, both_versions_registered, new_objects_exist, mobile_is_nullable,
    functions_executable_by_anon, newly_leaked_functions,
    customers_fingerprint_unchanged, profiles_fingerprint_unchanged, audit_log_fingerprint_unchanged, applied_at
  )
  values (
    v_schema_version, v_rpc_version, true, v_new_objects_exist, v_mobile_nullable,
    v_anon_exec, v_newly_leaked,
    (v_cust_count_after = v_cust_count_before and v_cust_md5_after = v_cust_md5_before),
    (v_prof_count_after = v_prof_count_before and v_prof_md5_after = v_prof_md5_before),
    (v_audit_count_after = v_audit_count_before and v_audit_md5_after = v_audit_md5_before),
    now()
  );
end
$apply$;

select * from pg_temp.customer_auto_onboard_apply_status;
