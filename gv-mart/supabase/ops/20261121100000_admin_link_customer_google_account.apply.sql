-- GO APPLY script for migration 20261121100000_admin_link_customer_google_account.sql (master-
-- only Google-account-linking stopgap: 2 brand-new SECURITY DEFINER functions, nothing else),
-- branch manual-link.
--
-- WRITTEN against the approved template (supabase/ops/20261108100000_customer_water_profile.apply.sql).
-- The owner runs or authorizes this after 11:00 IST, once satisfied the sha256-pinned migration
-- text embedded below is byte-for-byte the reviewed migration file (sha256
-- 527e0dd1d493145aebb94acd5ebf8ca31647dac43794d751b8cdd39a12ce68e1), that the DRYRUN copy of
-- THIS SAME apply script (20261121100000_admin_link_customer_google_account.apply.dryrun.sql)
-- came back clean against live data, and that the live rehearsal of the bare migration+test
-- (20261121100000_admin_link_customer_google_account.rehearsal.sql) came back clean (it did --
-- 25/25 PASS, zero real-row drift on customers/profiles/audit_log).
--
-- UPDATE/BACKFILL: NONE. No existing table, column, type or function is altered or dropped --
-- only 2 brand-new functions are created plus their own grants. There is nothing for a
-- traditional pg_dump-style backup to protect against here beyond what the BEFORE fingerprint
-- below already proves (and re-proves AFTER): no existing row in customers, profiles or
-- audit_log is read, written, or re-shaped by this migration. If either new function is ever
-- used after this applies, that use writes ordinary new rows (a profile, an audit_log entry) --
-- not a schema change -- and is undone, if ever needed, by the rollback script (drops the 2
-- functions; any data they already wrote is left alone, same as the template's own convention).
--
-- Order of operations inside the DO block:
--   0. ORG CHECK    -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation must
--      equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK         -- lock_timeout = 5s for this transaction only.
--   2. GATE         -- refuses before 11:00 IST.
--   3. ALREADY-REGISTERED CHECK -- refuses if supabase_migrations.schema_migrations already has
--      a row for version 20261121100000.
--   4. NEW-OBJECT PRE-CHECK -- neither admin_link_customer_google_account(uuid,text) nor
--      admin_unlink_customer_google_account(uuid,text) may already exist live.
--   5. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers
--      AND profiles, over REAL organisations only, plus the same formula for audit_log -- the
--      exact formula the rehearsal used.
--   6. LEAK SNAPSHOT (BEFORE) -- the full list of public-schema functions already executable by
--      PUBLIC/anon.
--   7. PIN          -- CR-tolerant sha256 of the embedded migration text must equal the pinned
--      LF hash.
--   8. RUN          -- EXECUTE the pinned migration text verbatim (CR-tolerant).
--   9. REGISTER     -- INSERT the version row into supabase_migrations.schema_migrations, in the
--      same transaction as the migration itself.
--   10. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      10a. both new functions now exist;
--      10b. DIFF-BASED leak check -- recompute the PUBLIC/anon-executable function list and diff
--          it against the BEFORE snapshot;
--      10c. ABSOLUTE check -- anon/PUBLIC cannot execute either new function, independent of 10b;
--      10d. the real customers/profiles/audit_log fingerprints are all unchanged from step 5 --
--          this migration touches no existing row.
--   11. On success, INSERT the one status row into pg_temp.admin_link_customer_google_account_apply_status.
--
-- No test file is embedded here (the rehearsal already ran it live, separately, against a
-- throwaway transaction) and there is no rollback invoked automatically -- any rollback for this
-- migration is run by hand, outside this script, only if the owner decides afterwards to undo it.

-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.admin_link_customer_google_account_apply_status;
create temp table admin_link_customer_google_account_apply_status (
  migration_version               text,
  version_registered              boolean,
  new_objects_exist               boolean,
  functions_executable_by_anon    boolean,
  newly_leaked_functions          text[],
  customers_fingerprint_unchanged boolean,
  profiles_fingerprint_unchanged  boolean,
  audit_log_fingerprint_unchanged boolean,
  applied_at                      timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                  int;
  v_expected_org_fingerprint  text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint           text;
  v_expected_migration_hash   text := '527e0dd1d493145aebb94acd5ebf8ca31647dac43794d751b8cdd39a12ce68e1';
  v_actual_migration_hash     text;
  v_migration_version         text := '20261121100000';
  v_already_registered        boolean;
  v_new_objects_exist         boolean := true;
  v_anon_exec                 boolean := false;
  v_leaked_before             text[];
  v_leaked_after              text[];
  v_newly_leaked              text[];
  v_cust_count_before         bigint; v_cust_md5_before text;
  v_cust_count_after          bigint; v_cust_md5_after  text;
  v_prof_count_before         bigint; v_prof_md5_before text;
  v_prof_count_after          bigint; v_prof_md5_after  text;
  v_audit_count_before        bigint; v_audit_md5_before text;
  v_audit_count_after         bigint; v_audit_md5_after  text;
  v_embedded_migration        text := $linkmig$-- Master-only stopgap for linking a customer's Google sign-in while OTP
-- linking (docs/spec-link-customer-login-phone-otp.md) is parked. The old
-- link_customer_google_account(text) RPC trusted whatever mobile number the
-- SIGNED-IN CALLER typed (account-takeover: anyone could type any customer's
-- mobile and claim their record) and stays revoked — see
-- 20261021100000_revoke_link_customer_google_account.sql. This is a
-- different trust model: the MASTER, already looking at one specific
-- customer's detail page, types the Google email that customer told them
-- they signed in with. No customer-facing surface is touched or notified.
--
-- Match-by-email, not match-by-mobile: the Google sign-in is identified by
-- its auth.identities row (provider = 'google'), not auth.users.email —
-- auth.users.email can in principle be set by other means, whereas the
-- identity row is what Supabase recorded at the actual Google OAuth
-- handshake. Email is lower()+trim()'d on both sides to close the
-- whitespace/case tricks called out in the security review.
--
-- Any auth user that already has a profiles row — customer, staff,
-- technician, whoever — is refused. This is deliberate and covers "linking
-- an auth user that belongs to a staff/technician": staff and technicians
-- always have a profiles row, so they can never match here.
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

  -- Row lock first: serializes two masters acting on the same customer
  -- concurrently (one linking, one unlinking, or two different emails).
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

  -- SECURITY REVIEW (2026-10-29) — deliberate trust boundary, accepted not fixed:
  -- this lookup is NOT org-scoped (auth.identities has no org_id; it is shared
  -- across every tenant). A master could in principle type an arbitrary email
  -- for one of their own customers and learn, from which of no_matching_signin /
  -- ambiguous_signin / signin_already_linked / success comes back, whether that
  -- exact email has ever signed in via Google anywhere in the system, and
  -- whether it's already attached to some profile — without ever being told
  -- which org. Accepted because: (a) a master is already one of the most
  -- privileged roles in this system, with standing access to every one of
  -- their own org's customers' full records; (b) the task this RPC exists for
  -- explicitly calls for a clear, specific refusal message to the master in
  -- each of these cases ("since the master is trusted") — collapsing them into
  -- one generic error would directly contradict that and make the tool harder
  -- to use for its actual job with no corresponding benefit, since the
  -- information this leaks (an email's bare existence somewhere, not which
  -- org) is not itself sensitive in the way an org's customer list is. Revisit
  -- if masters are ever a less-trusted role than they are today.
  --
  -- Reject on >1 match too: an ambiguous email should never silently pick
  -- "the first one", it should refuse and say so.
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
    -- lost a race against a concurrent call for a DIFFERENT customer that matched the same sign-in
    raise exception 'signin_already_linked';
  end;

  update public.customers set primary_profile_id = v_auth_id where id = v_customer.id;

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

-- Undo for a mistaken link. Deletes the profiles row entirely (not just
-- clearing customers.primary_profile_id) so the sign-in is fully reset to
-- its pre-link state and can be relinked — correctly, or to a different
-- customer — afterwards. If that profile has since accumulated rows that
-- reference it (anything beyond the bare customer link), the delete is
-- refused with a message rather than silently cascading.
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

  update public.customers set primary_profile_id = null where id = v_customer.id;

  begin
    delete from public.profiles where id = v_profile_id;
  exception when foreign_key_violation then
    raise exception 'unlink_blocked_has_records';
  end;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (
    v_customer.org_id, auth.uid(), 'admin_unlink_google_account', 'customers', v_customer.id,
    jsonb_build_object('primary_profile_id', v_profile_id),
    jsonb_build_object('primary_profile_id', null, 'reason', p_reason)
  );
end;
$$;

revoke all on function public.admin_unlink_customer_google_account(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_unlink_customer_google_account(uuid, text) to authenticated;
$linkmig$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint;
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
    raise exception 'APPLY_REFUSED: migration % is already registered in supabase_migrations.schema_migrations -- stop, nothing applied',
      v_migration_version;
  end if;

  -- 4. NEW-OBJECT PRE-CHECK.
  if to_regprocedure('public.admin_link_customer_google_account(uuid,text)') is not null then
    raise exception 'APPLY_REFUSED: public.admin_link_customer_google_account(uuid,text) already exists live before this migration ran';
  end if;
  if to_regprocedure('public.admin_unlink_customer_google_account(uuid,text)') is not null then
    raise exception 'APPLY_REFUSED: public.admin_unlink_customer_google_account(uuid,text) already exists live before this migration ran';
  end if;

  -- 5. REAL-TABLE FINGERPRINT (BEFORE) -- same formula the rehearsal used.
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

  -- 6. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
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

  -- 7. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 8. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 9. REGISTER -- record this migration as applied, in the same transaction as the migration itself.
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'admin_link_customer_google_account', array[replace(v_embedded_migration, E'\r', '')]);

  -- 10a. both new functions exist.
  v_new_objects_exist :=
    (to_regprocedure('public.admin_link_customer_google_account(uuid,text)') is not null)
    and (to_regprocedure('public.admin_unlink_customer_google_account(uuid,text)') is not null);
  if not v_new_objects_exist then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one or both new functions are missing after the migration ran';
  end if;

  -- 10b. DIFF-BASED leak check -- only entries NEW (present after, absent before) fail this check.
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
  from (
    select unnest(v_leaked_after) as x
    except
    select unnest(v_leaked_before)
  ) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 10c. ABSOLUTE checks -- anon/PUBLIC cannot execute either new function.
  if has_function_privilege('anon', 'public.admin_link_customer_google_account(uuid,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.admin_unlink_customer_google_account(uuid,text)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one new function is executable by anon/PUBLIC';
  end if;

  -- 10d. the real customers/profiles/audit_log fingerprints are all unchanged.
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- real customers fingerprint changed (count before % after %, md5 before % after %)',
      v_cust_count_before, v_cust_count_after, v_cust_md5_before, v_cust_md5_after;
  end if;
  if v_prof_count_after is distinct from v_prof_count_before or v_prof_md5_after is distinct from v_prof_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real profiles fingerprint changed (count before % after %, md5 before % after %)',
      v_prof_count_before, v_prof_count_after, v_prof_md5_before, v_prof_md5_after;
  end if;
  if v_audit_count_after is distinct from v_audit_count_before or v_audit_md5_after is distinct from v_audit_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real audit_log fingerprint changed (count before % after %, md5 before % after %)',
      v_audit_count_before, v_audit_count_after, v_audit_md5_before, v_audit_md5_after;
  end if;

  -- 11. Every step above passed -- record the one status row.
  insert into pg_temp.admin_link_customer_google_account_apply_status (
    migration_version, version_registered, new_objects_exist, functions_executable_by_anon,
    newly_leaked_functions, customers_fingerprint_unchanged, profiles_fingerprint_unchanged,
    audit_log_fingerprint_unchanged, applied_at
  )
  values (
    v_migration_version, true, v_new_objects_exist, v_anon_exec,
    v_newly_leaked,
    (v_cust_count_after = v_cust_count_before and v_cust_md5_after = v_cust_md5_before),
    (v_prof_count_after = v_prof_count_before and v_prof_md5_after = v_prof_md5_before),
    (v_audit_count_after = v_audit_count_before and v_audit_md5_after = v_audit_md5_before),
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.admin_link_customer_google_account_apply_status;
