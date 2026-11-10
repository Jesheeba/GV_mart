-- GO APPLY script for 20261204130000_duplicate_contact_warning_rpc.sql (find_duplicate_contacts
-- RPC + the public._mobile_key(text) authenticated grant it needs). branch
-- feat/urgent-duplicate-customer-flow.
--
-- Full rehearsal (functional matrix as real sales_admin/operation_admin/technician/customer/anon
-- roles, cross-org isolation, test-row exclusion including the is_test cascade case, LIMIT 10
-- cap + ordering, normalized-mobile matching, email-only matching, structural/grant/search_path
-- checks) ran clean: 24/24 PASS, fully rolled back, nothing persisted --
-- _local_only/worktrees/urgent-dup-customer-flow/_local_only_reports_dup_contacts_rehearsal_20261204130000.sql.out.txt.
--
-- Order of operations inside the DO block:
--   0. ORG CHECK        -- md5(id||'|'||name) of the oldest real (non __TEST_) organisation
--                           must equal the pinned fingerprint 6f891cf85011f08c2f22fb4a208d21bd.
--   1. LOCK             -- lock_timeout = 5s for this transaction only.
--   2. ALREADY-REGISTERED CHECK -- refuses if 20261204130000 is already registered.
--   3. NEW-OBJECT PRE-CHECK -- public.find_duplicate_contacts(text,text) must not already exist.
--   3b. LIVE-DEFINITION PRE-CHECK -- CR-tolerant sha256 of current_org_id(), is_staff() and
--                           _mobile_key(text) must equal their pinned hashes (re-checked right
--                           before the apply, catching drift since the rehearsal); also confirms
--                           _mobile_key(text) does NOT yet have an authenticated grant (so the
--                           migration's new grant line is adding something real, not a no-op).
--   4. REAL-TABLE FINGERPRINT (BEFORE) -- count + md5(string_agg(id||updated_at)) of customers
--                           and leads, over REAL organisations only. This migration does not
--                           write to either table, so these must be identical after.
--   5. LEAK SNAPSHOT (BEFORE) -- every public-schema function already executable by PUBLIC/anon.
--   6. PIN              -- CR-tolerant sha256 of the embedded migration text must equal the
--                           pinned hash of the committed file.
--   7. RUN              -- EXECUTE the migration, verbatim (CR-tolerant).
--   8. REGISTER         -- INSERT the version row into supabase_migrations.schema_migrations,
--                           in the same transaction as the migration itself.
--   9. POST-APPLY CHECKS (read-only, each raises immediately if wrong):
--      9a. find_duplicate_contacts(text,text) exists with the expected 2-arg, 8-column-table
--          signature; _mobile_key(text) still exists (not dropped/redefined away);
--      9b. grants: anon/public cannot execute find_duplicate_contacts; authenticated and
--          service_role can; authenticated can now execute _mobile_key(text) too;
--      9c. DIFF-BASED leak check against the BEFORE snapshot -- 0 new anon/PUBLIC-executable
--          functions expected (find_duplicate_contacts explicitly revokes public/anon in the
--          same migration, and the only other grant change, _mobile_key -> authenticated, is
--          not anon/PUBLIC either);
--      9d. ABSOLUTE check -- anon/PUBLIC cannot execute find_duplicate_contacts(text,text) or
--          _mobile_key(text), independent of 9c;
--      9e. the real customers/leads fingerprints are unchanged from step 4.
--   10. On success, INSERT the one status row into pg_temp.dup_contacts_apply_status.
--
-- No rollback script is needed beyond `drop function public.find_duplicate_contacts(text,text);
-- revoke execute on function public._mobile_key(text) from authenticated;` -- both brand-new
-- grant surface, nothing redefined or dropped from anything pre-existing.

drop table if exists pg_temp.dup_contacts_apply_status;
create temp table dup_contacts_apply_status (
  version_registered          text,
  function_exists              boolean,
  mobile_key_still_exists      boolean,
  grants_correct               boolean,
  functions_executable_by_anon boolean,
  newly_leaked_functions       text[],
  customers_fingerprint_unchanged boolean,
  leads_fingerprint_unchanged      boolean,
  applied_at                   timestamptz
);

do $apply$
declare
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint text;
  v_expected_migration_hash text := 'f7aa7bf9d7ea7e9c28467e0a0d41b45afc2026d15f6cffb13db490398e3f139c';
  v_actual_hash text;
  v_expected_current_org_id_hash text := 'e5d48c6765490f6a27149f92b74f35071cf498c888e44a2f4620f1c70336b5cc';
  v_expected_is_staff_hash text := '9ea335cedbecb8b0f7ff5db7875a471cae216240759038c8470cccf5d7c62bcc';
  v_expected_mobile_key_hash text := '10095e477fb8cd5b90f6ade3985b591aa59fbe902babb553ad948bf977fa7c7d';
  v_live_hash text;
  v_already_registered boolean;
  v_function_exists boolean := false;
  v_mobile_key_exists boolean := false;
  v_grants_correct boolean := false;
  v_anon_exec boolean := false;
  v_leaked_before text[];
  v_leaked_after text[];
  v_newly_leaked text[];
  v_cust_count_before bigint; v_cust_md5_before text;
  v_cust_count_after bigint; v_cust_md5_after text;
  v_leads_count_before bigint; v_leads_md5_before text;
  v_leads_count_after bigint; v_leads_md5_after text;
  v_migration_text text;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST\_%' escape '\'
  order by o.created_at asc, o.id asc
  limit 1;
  if v_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. ALREADY-REGISTERED CHECK
  select exists(select 1 from supabase_migrations.schema_migrations where version = '20261204130000') into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: 20261204130000 is already registered in supabase_migrations.schema_migrations -- stop, nothing applied';
  end if;

  -- 3. NEW-OBJECT PRE-CHECK
  if to_regprocedure('public.find_duplicate_contacts(text,text)') is not null then
    raise exception 'APPLY_REFUSED: public.find_duplicate_contacts(text,text) already exists live before this migration ran';
  end if;

  -- 3b. LIVE-DEFINITION PRE-CHECK -- re-pin the three live dependency functions right before
  -- creating anything, and confirm _mobile_key(text) does not already have the grant we're about
  -- to add (so step 9b's "grants_correct" check is proving something, not trivially true).
  v_live_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.current_org_id()'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_live_hash is distinct from v_expected_current_org_id_hash then
    raise exception 'APPLY_REFUSED: live current_org_id() no longer matches the pinned body (expected %, got %) -- someone changed it since this migration was rehearsed', v_expected_current_org_id_hash, v_live_hash;
  end if;
  v_live_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public.is_staff()'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_live_hash is distinct from v_expected_is_staff_hash then
    raise exception 'APPLY_REFUSED: live is_staff() no longer matches the pinned body (expected %, got %) -- someone changed it since this migration was rehearsed', v_expected_is_staff_hash, v_live_hash;
  end if;
  v_live_hash := encode(sha256(convert_to(replace(pg_get_functiondef('public._mobile_key(text)'::regprocedure), E'\r', ''), 'UTF8')), 'hex');
  if v_live_hash is distinct from v_expected_mobile_key_hash then
    raise exception 'APPLY_REFUSED: live _mobile_key(text) no longer matches the pinned body (expected %, got %) -- someone changed it since this migration was rehearsed', v_expected_mobile_key_hash, v_live_hash;
  end if;
  if has_function_privilege('authenticated', 'public._mobile_key(text)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: public._mobile_key(text) already grants EXECUTE to authenticated before this migration ran -- the pre-state assumption behind this migration no longer holds';
  end if;

  -- 4. REAL-TABLE FINGERPRINT (BEFORE)
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_before, v_cust_md5_before
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_leads_count_before, v_leads_md5_before
  from public.leads
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

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

  -- 6. PIN
  v_migration_text := $migration$-- Staff-side duplicate-contact warning RPC (urgent item, 2026-11-02 investigation).
--
-- Context: owner reported "when creating a customer with an existing number, I
-- see an error popup YET one entry still gets created." Root-cause investigation
-- (code read + live, read-only queries, no writes) found:
--   * create_customer_with_details has NO dedupe check, by design -- a manual
--     "Create Customer" is always a new row (confirmed in both the live function
--     body via pg_get_functiondef and the unapplied 20261204120000 migration --
--     no pg_sleep/savepoints/subtransactions either, so Postgres atomicity holds;
--     a single call either fully commits or fully rolls back, it never leaves a
--     partial insert behind).
--   * The existing inline duplicate hint (useMobileDuplicateCheck /
--     customers.form.duplicateWarning, shown per-member in CustomerFormPage) is
--     informational only -- it never re-runs at Save time and never blocks Save.
--   * Live evidence (read-only, 2026-10-17 onward, is_test excluded): 6 real
--     (org_id, mobile) duplicate pairs with gaps of ~5 minutes to ~24 hours --
--     i.e. ordinary, separate single-submit creates, NOT a sub-second
--     double-click race. That matches this mechanism exactly: staff sees (or
--     misses) the quiet inline hint, proceeds anyway, and the RPC -- which has
--     no enforcement -- happily creates another row for the same number.
--   * Separately (not fixed here -- flagged for the owner): CustomerFormPage's
--     Save button has no guardReentry (src/lib/async-guard.ts) wiring, unlike
--     AccountsPage's "+ Create" buttons, so a fast double-click could ALSO
--     create two rows via two concurrent RPC calls. No live evidence of that
--     specific pattern was found (no sub-2-second-gap pairs), so it is reported
--     as a latent gap, not the confirmed cause. Note too that even once the
--     unapplied 20261204120000 advisory-lock migration lands, it would not
--     close this gap -- that lock only serializes a manual create against the
--     two lead-conversion paths' check-then-act, not a manual create against a
--     second concurrent manual create of itself (the function still inserts
--     unconditionally after taking the lock).
--
-- This migration is the long-term mitigation for the confirmed mechanism above:
-- a read-only RPC the staff-side Create Customer / Create Lead forms can call
-- live (debounced, on blur/change of the mobile field) to show a non-blocking
-- "existing record(s) found" banner with enough context (name, mobile, email,
-- created_at, ticket/invoice counts) for staff to make an informed call, plus
-- an explicit "Create anyway" confirmation step once a match is shown -- same
-- "never pre-emptive, only once a real conflict is flagged" shape as
-- assign_ticket_technician's p_force override (TicketDetailPage.tsx).
--
-- This RPC does NOT enforce anything server-side (by design, matching the
-- existing "manual create is always new" convention) and does NOT merge/filter
-- the already-known 2026-10-16 bulk-import placeholder-mobile duplicates --
-- that is a separate, not-yet-decided cleanup problem. It only answers "does
-- this org already have a customer or lead with this mobile/email right now."
--
-- Security model: SECURITY INVOKER, not DEFINER. The three tables it reads
-- (customers, leads, service_tickets/invoices via subselects) already have
-- RLS policies granting SELECT to is_staff() within current_org_id()
-- (customers_select_staff / leads_select_staff / service_tickets_select_staff /
-- invoices_select_staff, all from 20260701091300_rls.sql) -- so INVOKER rides
-- those existing policies instead of bypassing them, which is strictly safer
-- than DEFINER for a function that does nothing a staff member couldn't
-- already do with four individual SELECTs. The explicit is_staff()/org guard
-- below is defense-in-depth (a clear exception instead of a silent empty
-- result for a non-staff caller), not the only thing standing between this
-- function and someone else's org.
--
-- NOT APPLIED. Needs the standard pipeline: rehearsal (as the real
-- authenticated staff role, not service_role), DRYRUN-OK, a fresh security
-- review, an anon-exposure diff, and the owner's typed APPROVED.
--
-- Found during rehearsal (2026-11-03): public._mobile_key(text) is SECURITY
-- INVOKER with no EXECUTE grant to authenticated (it was only ever called
-- from inside other SECURITY DEFINER functions before this one, which run
-- with the definer's own privileges regardless of the caller). This function
-- is SECURITY INVOKER by design (see above) -- its nested call to
-- _mobile_key() runs as the actual caller (sales_admin/operation_admin via
-- the authenticated role), not elevated, so without this grant every real
-- call would fail with "permission denied for function _mobile_key" before
-- ever reaching the table scan. _mobile_key is a pure, IMMUTABLE string
-- transform (last 10 digits of the input, no table access, no side effects)
-- -- widening its EXECUTE grant to authenticated is safe and adds no new
-- capability beyond what every other normalized-mobile comparison in this
-- project already does internally.
grant execute on function public._mobile_key(text) to authenticated;

create or replace function public.find_duplicate_contacts(
  p_mobile text default null,
  p_email text default null
)
returns table (
  source text,
  id uuid,
  name text,
  mobile text,
  email text,
  created_at timestamptz,
  ticket_count bigint,
  invoice_count bigint
)
language plpgsql
stable
security invoker
set search_path to 'public'
as $function$
declare
  v_org_id uuid := public.current_org_id();
  -- _mobile_key (20261016110000_test_customer_flag.sql, already live) -- last
  -- 10 digits only. Deliberately NOT the unapplied 2A migration's
  -- normalize_mobile (country-code/trunk-prefix aware): that function does not
  -- exist live yet, and this RPC must work independently of whether/when that
  -- other migration is ever approved.
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  -- Nothing to match on -- return no rows rather than scanning the org.
  if v_mobile_key is null and v_email = '' then
    return;
  end if;

  return query
  select * from (
    select
      'customer'::text as source,
      c.id,
      c.name,
      c.mobile,
      c.email,
      c.created_at,
      (select count(*) from public.service_tickets t where t.customer_id = c.id)::bigint as ticket_count,
      (select count(*) from public.invoices i where i.customer_id = c.id)::bigint as invoice_count
    from public.customers c
    where c.org_id = v_org_id
      and not c.is_test
      and (
        (v_mobile_key is not null and public._mobile_key(c.mobile) = v_mobile_key)
        or (v_email <> '' and lower(c.email) = v_email)
      )
    union all
    -- Leads have no email column -- mobile-only match. Always zero
    -- ticket/invoice counts (a lead isn't a customer yet).
    select
      'lead'::text,
      l.id,
      l.name,
      l.mobile,
      null::text,
      l.created_at,
      0::bigint,
      0::bigint
    from public.leads l
    where l.org_id = v_org_id
      and not l.is_test
      and v_mobile_key is not null
      and public._mobile_key(l.mobile) = v_mobile_key
  ) matches
  order by created_at desc
  limit 10;
end;
$function$;

-- EXECUTE revoked explicitly from public/anon below -- this project
-- auto-grants it on new functions by default (see the 20260827
-- default_privileges_anon_execute_leak fix); always revoke explicitly rather
-- than relying on no default grant.
revoke all on function public.find_duplicate_contacts(text, text) from public, anon;
grant execute on function public.find_duplicate_contacts(text, text) to authenticated, service_role;
$migration$;

  v_actual_hash := encode(sha256(convert_to(replace(v_migration_text, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_hash;
  end if;

  -- 7. RUN
  execute replace(v_migration_text, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261204130000', 'duplicate_contact_warning_rpc', array[replace(v_migration_text, E'\r', '')]);

  -- 9a. function exists with the expected signature; _mobile_key still exists.
  v_function_exists := to_regprocedure('public.find_duplicate_contacts(text,text)') is not null;
  if not v_function_exists then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.find_duplicate_contacts(text,text) is missing after the migration ran';
  end if;
  v_mobile_key_exists := to_regprocedure('public._mobile_key(text)') is not null;
  if not v_mobile_key_exists then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public._mobile_key(text) is missing after the migration ran';
  end if;

  -- 9b. grants.
  v_grants_correct :=
    (not has_function_privilege('anon', 'public.find_duplicate_contacts(text,text)', 'EXECUTE'))
    and (not has_function_privilege('public', 'public.find_duplicate_contacts(text,text)', 'EXECUTE'))
    and has_function_privilege('authenticated', 'public.find_duplicate_contacts(text,text)', 'EXECUTE')
    and has_function_privilege('service_role', 'public.find_duplicate_contacts(text,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public._mobile_key(text)', 'EXECUTE');
  if not v_grants_correct then
    raise exception 'APPLY_REFUSED: post-apply check failed -- grants on find_duplicate_contacts/_mobile_key are not as expected';
  end if;

  -- 9c. DIFF-BASED leak check.
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon: %', array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 9d. ABSOLUTE checks.
  if has_function_privilege('anon', 'public.find_duplicate_contacts(text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public._mobile_key(text)', 'EXECUTE') then
    v_anon_exec := true;
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one function is executable by anon';
  end if;

  -- 9e. real fingerprints unchanged (this migration writes no data).
  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_cust_count_after, v_cust_md5_after
  from public.customers
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  select count(*), md5(coalesce(string_agg(id::text || updated_at::text, '' order by id), ''))
    into v_leads_count_after, v_leads_md5_after
  from public.leads
  where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  if v_cust_count_after is distinct from v_cust_count_before or v_cust_md5_after is distinct from v_cust_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real customers fingerprint changed (count before % after %, md5 before % after %)', v_cust_count_before, v_cust_count_after, v_cust_md5_before, v_cust_md5_after;
  end if;
  if v_leads_count_after is distinct from v_leads_count_before or v_leads_md5_after is distinct from v_leads_md5_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real leads fingerprint changed (count before % after %, md5 before % after %)', v_leads_count_before, v_leads_count_after, v_leads_md5_before, v_leads_md5_after;
  end if;

  -- 10. Every step above passed.
  insert into pg_temp.dup_contacts_apply_status (
    version_registered, function_exists, mobile_key_still_exists, grants_correct,
    functions_executable_by_anon, newly_leaked_functions,
    customers_fingerprint_unchanged, leads_fingerprint_unchanged, applied_at
  )
  values (
    '20261204130000', v_function_exists, v_mobile_key_exists, v_grants_correct,
    v_anon_exec, v_newly_leaked,
    (v_cust_count_after = v_cust_count_before and v_cust_md5_after = v_cust_md5_before),
    (v_leads_count_after = v_leads_count_before and v_leads_md5_after = v_leads_md5_before),
    now()
  );
end
$apply$;

select * from pg_temp.dup_contacts_apply_status;
