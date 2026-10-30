-- GO APPLY script for the full customer_auto_onboard migration chain:
--   20261130100000_customer_auto_onboard_schema.sql
--   20261130100001_customer_auto_onboard_rpc.sql
--   20261130100002_unlink_blocks_auto_relink.sql
--   20261130100003_merge_auto_customer.sql
-- branch feat/customer-auto-onboard.
--
-- BEFORE running this: run the backup step (20261130100000_customer_auto_onboard.backup.sql,
-- via the same run_rehearsal.mjs runner -- no Supabase dashboard involved) and save its output
-- durably. See that file's own header for exactly what it captures and why that's the complete
-- "what could this migration lose" surface -- everything else this chain touches is a brand-new
-- column or function.
--
-- WRITTEN against the approved template (supabase/ops/20261108100000_customer_water_profile.apply.sql,
-- also used by 20261121100000_admin_link_customer_google_account.apply.sql). The owner runs or
-- authorizes this after: (1) the backup step above, (2) the DRYRUN copy of THIS SAME apply
-- script came back clean against live data, (3) the live rehearsal of all 4 migrations + the
-- test file + the rollback script came back clean (it did -- 42/42 test assertions PASS,
-- rollback_ok=t, independently re-verified in separate requests that nothing persisted).
--
-- UPDATE/BACKFILL: NONE for any existing row. Every column 20261130100000 adds is new,
-- nullable/defaulted -- every existing row gets NULL/false, the correct "not auto-onboarded /
-- not blocked / not archived" state for a row that predates this feature. customers.mobile NOT
-- NULL -> nullable touches no existing row's value. 20261130100002 redefines two already-live
-- functions (admin_link_customer_google_account / admin_unlink_customer_google_account,
-- 20261121100000) with exactly one added line each -- confirmed by diff against their live
-- bodies before this was written. 20261130100003 is a brand-new function.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. GATE             -- refuses before 11:00 IST.
--   3. ALREADY-REGISTERED CHECK -- refuses if ANY of the 4 versions is already registered.
--   4. NEW-OBJECT PRE-CHECK -- the 5 new customers columns, customer_auto_onboard() and
--                           admin_merge_auto_customer() must not already exist; customers.mobile
--                           must currently be NOT NULL.
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers,
--                           profiles, audit_log, over REAL organisations only.
--   6. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
--   7. PIN              -- CR-tolerant sha256 of all 4 embedded migration texts must equal their
--                           pinned hashes.
--   8. RUN              -- EXECUTE all 4 migrations, verbatim (CR-tolerant), in order.
--   9. REGISTER         -- INSERT all 4 version rows into supabase_migrations.schema_migrations,
--                           in the same transaction as the migrations themselves.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. all 5 new columns and both new functions exist; customers.mobile is now nullable;
--          admin_link_customer_google_account / admin_unlink_customer_google_account still
--          exist (redefined, not dropped);
--      10b. DIFF-BASED leak check against the BEFORE snapshot;
--      10c. ABSOLUTE check -- anon/PUBLIC cannot execute customer_auto_onboard() or
--          admin_merge_auto_customer(uuid,uuid,text), independent of 10b;
--      10d. the real customers/profiles/audit_log fingerprints are all unchanged from step 5.
--   11. On success, INSERT the one status row into pg_temp.customer_auto_onboard_apply_status.
--
-- No test file is embedded here (the rehearsal already ran it live, separately, against a
-- throwaway transaction) and there is no rollback invoked automatically -- see
-- supabase/rollbacks/20261130100000_customer_auto_onboard.rollback.sql, already tested in the
-- rehearsal, for the hand-run undo.

drop table if exists pg_temp.customer_auto_onboard_apply_status;
create temp table customer_auto_onboard_apply_status (
  versions_registered             text[],
  new_objects_exist                boolean,
  mobile_is_nullable               boolean,
  admin_link_unlink_still_exist    boolean,
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
  v_expected_schema_hash      text := '58487f324dcd17b5d5ac6f5db81b8be5737b18fab2f3bc40fbc2d4c28c750c28';
  v_expected_rpc_hash         text := '46c63f7ba8a24ebbe90cea4f0216d9ea2a7219e442657fa255bf6c8345c28f81';
  v_expected_unlink_hash      text := '855f458797428e5b442d1a5b1ba511d96ae13b539d7ad75eea18421fd4d960cf';
  v_expected_merge_hash       text := '62b21eb1bc1834da1bfa3ba94e8af2bbf0d71cb4e569162120fcb9fe92a0a6e7';
  v_actual_hash               text;
  v_versions                  text[] := array['20261130100000', '20261130100001', '20261130100002', '20261130100003'];
  v_already_registered        boolean;
  v_new_objects_exist          boolean := true;
  v_mobile_nullable            boolean := false;
  v_admin_link_unlink_ok       boolean := false;
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
$rpcmig$;
  v_embedded_unlink text := $unlinkmig$-- Closes the "unlink loop": without this, a master's admin_unlink_customer_google_account
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
$unlinkmig$;
  v_embedded_merge text := $mergemig$-- Master-only merge tool: attaches an auto-created ('app') or needs_review customer's Google
-- sign-in to an existing, already-known customer record -- the counterpart to
-- admin_link_customer_google_account for the one case that tool refuses: the auth user already
-- has a profile (every auto-created customer does, by design -- customer_auto_onboard always
-- links the new sign-in to whatever it creates). This is the correct tool for "a returning
-- customer signed in with Google before staff had a chance to find their existing record" --
-- not a general-purpose customer-merge (it refuses outright unless the auto-created side is
-- completely empty, see below), and never auto-applied -- a master always chooses the target.
--
-- customers.archived_at / archived_by: NEW. The emptied auto-created record is archived, not
-- hard-deleted -- its audit_log history (auto_create, and now this merge) stays attached to a
-- real row, same reasoning admin_unlink_customer_google_account's own header gives for deleting
-- profiles but never customers. Archived customers are excluded from the admin customer list and
-- search by default (frontend, same migration's sibling PR) but the row itself, and its
-- audit_log trail, is never removed.
alter table public.customers add column archived_at timestamptz;
alter table public.customers add column archived_by uuid references public.profiles (id) on delete set null;

-- Reuses customer_delete_impact's exact counts (20261005140000_delete_customer.sql) for the
-- "completely empty" check -- tickets (visits), amc_contracts/warranties/rental_contracts
-- (lifecycle), quotations and invoices (orders/payments). Deliberately does NOT check
-- addresses/customer_members -- those aren't lifecycle data and the spec doesn't ask for it; an
-- auto-created customer who has typed in their own address before a master gets to it should
-- still be mergeable (the address itself doesn't move -- it stays with the archived record,
-- same as any other data on a customer that already has invoices would with an outright delete).
create or replace function public.admin_merge_auto_customer(p_from_customer_id uuid, p_to_customer_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from public.customers;
  v_to public.customers;
  v_auth_id uuid;
  v_tickets int; v_amc int; v_warranties int; v_rentals int; v_quotations int; v_invoices int;
begin
  if auth.uid() is null then
    raise exception 'admin_merge_auto_customer: no authenticated user';
  end if;
  if not public.is_master() then
    raise exception 'admin_merge_auto_customer: master role required';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'reason_required';
  end if;
  if p_from_customer_id = p_to_customer_id then
    raise exception 'same_customer';
  end if;

  -- Lock in a fixed order (by id) regardless of which argument is which, so two concurrent
  -- merges touching the same pair of rows in opposite order can never deadlock.
  if p_from_customer_id < p_to_customer_id then
    select * into v_from from public.customers where id = p_from_customer_id for update;
    select * into v_to from public.customers where id = p_to_customer_id for update;
  else
    select * into v_to from public.customers where id = p_to_customer_id for update;
    select * into v_from from public.customers where id = p_from_customer_id for update;
  end if;

  if v_from.id is null or v_from.org_id is distinct from public.current_org_id() then
    raise exception 'from_customer_not_found';
  end if;
  if v_to.id is null or v_to.org_id is distinct from public.current_org_id() then
    raise exception 'to_customer_not_found';
  end if;

  if v_from.source is distinct from 'customer_app' then
    raise exception 'from_customer_not_auto_created';
  end if;
  if v_from.archived_at is not null then
    raise exception 'from_customer_already_archived';
  end if;
  if v_from.primary_profile_id is null then
    raise exception 'from_customer_not_linked';
  end if;

  if v_to.is_test then
    raise exception 'to_customer_is_test';
  end if;
  if v_to.archived_at is not null then
    raise exception 'to_customer_archived';
  end if;
  if v_to.primary_profile_id is not null then
    raise exception 'to_customer_already_linked';
  end if;

  select count(*) into v_tickets from public.service_tickets where customer_id = v_from.id;
  select count(*) into v_amc from public.amc_contracts where customer_id = v_from.id;
  select count(*) into v_warranties from public.warranties where customer_id = v_from.id;
  select count(*) into v_rentals from public.rental_contracts where customer_id = v_from.id;
  select count(*) into v_quotations from public.quotations where customer_id = v_from.id;
  select count(*) into v_invoices from public.invoices where customer_id = v_from.id;
  if v_tickets > 0 or v_amc > 0 or v_warranties > 0 or v_rentals > 0 or v_quotations > 0 or v_invoices > 0 then
    raise exception 'from_customer_has_records';
  end if;

  v_auth_id := v_from.primary_profile_id;

  -- Move the link: FROM must be cleared FIRST -- customers.primary_profile_id is UNIQUE, so
  -- setting TO's primary_profile_id while FROM still holds the same value would violate that
  -- constraint (caught by this migration's own rehearsal, not by inspection: two rows briefly
  -- sharing one primary_profile_id value, even within a single transaction, is checked
  -- immediately since the constraint isn't DEFERRABLE).
  update public.customers set primary_profile_id = null, archived_at = now(), archived_by = auth.uid() where id = v_from.id;
  update public.customers set primary_profile_id = v_auth_id, email = coalesce(v_to.email, v_from.email) where id = v_to.id;

  -- The profile's own display fields were set from the auto-created (FROM) customer at
  -- creation time -- now that it represents TO, bring them into line, same effect
  -- admin_link_customer_google_account's own link path already has for a fresh link.
  update public.profiles
    set org_id = v_to.org_id, full_name = coalesce(nullif(v_to.name, ''), 'Customer'), phone = v_to.mobile, language = coalesce(v_to.preferred_language, 'en')
    where id = v_auth_id;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_to.org_id, auth.uid(), 'admin_merge_auto_customer', 'customers', v_to.id,
    jsonb_build_object('primary_profile_id', null),
    jsonb_build_object('primary_profile_id', v_auth_id, 'merged_from_customer_id', v_from.id, 'reason', p_reason)
  );
  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_from.org_id, auth.uid(), 'admin_merge_auto_customer_archived', 'customers', v_from.id,
    jsonb_build_object('primary_profile_id', v_auth_id, 'archived_at', null),
    jsonb_build_object('primary_profile_id', null, 'archived_at', now(), 'merged_into_customer_id', v_to.id, 'reason', p_reason)
  );
end;
$$;

revoke all on function public.admin_merge_auto_customer(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_merge_auto_customer(uuid, uuid, text) to authenticated;
$mergemig$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST\_%' escape '\'
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
  select exists(select 1 from supabase_migrations.schema_migrations where version = any(v_versions)) into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: one of % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied', v_versions;
  end if;

  -- 4. NEW-OBJECT PRE-CHECK
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name in ('email', 'needs_review', 'needs_review_reason', 'auto_link_blocked_at', 'auto_link_blocked_by', 'archived_at', 'archived_by')) then
    raise exception 'APPLY_REFUSED: one of the new customers columns already exists live before this migration ran';
  end if;
  if to_regprocedure('public.customer_auto_onboard()') is not null then
    raise exception 'APPLY_REFUSED: public.customer_auto_onboard() already exists live before this migration ran';
  end if;
  if to_regprocedure('public.admin_merge_auto_customer(uuid,uuid,text)') is not null then
    raise exception 'APPLY_REFUSED: public.admin_merge_auto_customer(uuid,uuid,text) already exists live before this migration ran';
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
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_schema, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_schema_hash then
    raise exception 'APPLY_REFUSED: embedded schema migration text does not match its pinned sha256 (expected %, got %)', v_expected_schema_hash, v_actual_hash;
  end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_rpc, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_rpc_hash then
    raise exception 'APPLY_REFUSED: embedded rpc migration text does not match its pinned sha256 (expected %, got %)', v_expected_rpc_hash, v_actual_hash;
  end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_unlink, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_unlink_hash then
    raise exception 'APPLY_REFUSED: embedded unlink-block migration text does not match its pinned sha256 (expected %, got %)', v_expected_unlink_hash, v_actual_hash;
  end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_merge, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_merge_hash then
    raise exception 'APPLY_REFUSED: embedded merge migration text does not match its pinned sha256 (expected %, got %)', v_expected_merge_hash, v_actual_hash;
  end if;

  -- 8. RUN -- true dependency order: schema first (rpc/unlink/merge reference its columns).
  execute replace(v_embedded_schema, E'\r', '');
  execute replace(v_embedded_rpc, E'\r', '');
  execute replace(v_embedded_unlink, E'\r', '');
  execute replace(v_embedded_merge, E'\r', '');

  -- 9. REGISTER -- all 4 versions, same transaction as the migrations themselves.
  insert into supabase_migrations.schema_migrations (version, name, statements) values
    ('20261130100000', 'customer_auto_onboard_schema', array[replace(v_embedded_schema, E'\r', '')]),
    ('20261130100001', 'customer_auto_onboard_rpc', array[replace(v_embedded_rpc, E'\r', '')]),
    ('20261130100002', 'unlink_blocks_auto_relink', array[replace(v_embedded_unlink, E'\r', '')]),
    ('20261130100003', 'merge_auto_customer', array[replace(v_embedded_merge, E'\r', '')]);

  -- 10a. new objects exist; mobile is now nullable; admin_link/admin_unlink still exist.
  v_new_objects_exist :=
    (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'email'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'needs_review'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'needs_review_reason'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'auto_link_blocked_at'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'auto_link_blocked_by'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'archived_at'))
    and (exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'archived_by'))
    and (to_regprocedure('public.customer_auto_onboard()') is not null)
    and (to_regprocedure('public.admin_merge_auto_customer(uuid,uuid,text)') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or more new columns/functions are missing after the migrations ran';
  end if;

  select (is_nullable = 'YES') into v_mobile_nullable
  from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'mobile';
  if not coalesce(v_mobile_nullable, false) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customers.mobile is still NOT NULL after the schema migration ran';
  end if;

  v_admin_link_unlink_ok :=
    (to_regprocedure('public.admin_link_customer_google_account(uuid,text)') is not null)
    and (to_regprocedure('public.admin_unlink_customer_google_account(uuid,text)') is not null);
  if not v_admin_link_unlink_ok then
    raise exception 'APPLY_REFUSED: post-apply check failed -- admin_link_customer_google_account / admin_unlink_customer_google_account are missing after the redefinition';
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

  -- 10c. ABSOLUTE checks.
  if has_function_privilege('anon', 'public.customer_auto_onboard()', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_merge_auto_customer(uuid,uuid,text)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one new function is executable by anon/PUBLIC';
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
    versions_registered, new_objects_exist, mobile_is_nullable, admin_link_unlink_still_exist,
    functions_executable_by_anon, newly_leaked_functions,
    customers_fingerprint_unchanged, profiles_fingerprint_unchanged, audit_log_fingerprint_unchanged, applied_at
  )
  values (
    v_versions, v_new_objects_exist, v_mobile_nullable, v_admin_link_unlink_ok,
    v_anon_exec, v_newly_leaked,
    (v_cust_count_after = v_cust_count_before and v_cust_md5_after = v_cust_md5_before),
    (v_prof_count_after = v_prof_count_before and v_prof_md5_after = v_prof_md5_before),
    (v_audit_count_after = v_audit_count_before and v_audit_md5_after = v_audit_md5_before),
    now()
  );
end
$apply$;

select * from pg_temp.customer_auto_onboard_apply_status;
