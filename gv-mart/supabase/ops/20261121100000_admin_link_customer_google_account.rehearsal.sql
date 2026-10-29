-- Rehearsal wrapper for 20261121100000_admin_link_customer_google_account.sql.
-- One DO block. Refuses before 11:00 IST. Refuses unless the real (non-__TEST_) organisation
-- fingerprint pins to 6f891cf85011f08c2f22fb4a208d21bd (md5 of the earliest real org's id|name),
-- checked right after the time gate and before anything else, including the sha256 checks below.
-- Recomputes sha256 of the embedded migration and test text (encode(sha256(convert_to(text,
-- 'UTF8')),'hex') -- explicit UTF8 bytes, not a bytea cast) and compares against the pinned
-- hashes, which must match the committed .sql files exactly (LF line endings, no BOM -- both
-- confirmed on disk before this wrapper was written). Takes a real-org fingerprint of every
-- table this migration's functions can write to (customers, profiles, audit_log) before and
-- after -- both a plain row count AND a content checksum, so a same-count-but-mutated-row case
-- is caught too. Runs both migration and test via EXECUTE. No top-level BEGIN/COMMIT/SAVEPOINT/
-- ROLLBACK: the block always ends in an unconditional RAISE EXCEPTION, so the enclosing
-- statement aborts and nothing persists regardless of outcome -- the HTTP 400 / P0001 RESULTS
-- this produces is the intended result, not a failure.
--
-- No existing live function is redefined by this migration (confirmed: admin_link_customer_
-- google_account and admin_unlink_customer_google_account are both brand new -- nothing with
-- these names exists today), so there is no md5-live-definition pre-check section here; that
-- mechanism only applies when redefining something already live.
do $w$
declare
  v_migration text := $MIGRATION_BODY$-- Master-only stopgap for linking a customer's Google sign-in while OTP
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
$MIGRATION_BODY$;
  v_test text := $TEST_BODY$-- Rolled-back DB tests for 20261121100000_admin_link_customer_google_account.sql.
-- Run through the Management API (database/query); always ends in a RAISE so
-- nothing persists. Read RESULTS in the error. Creates its own __TEST_
-- organisations, users and a throwaway auth.identities (provider='google')
-- row per scenario -- never reads from or depends on whatever real data
-- already exists, other than a final real-row-count sanity check.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- pg_temp functions are not executable by `authenticated` by default -- the test switches role
-- via pg_temp.as_user() before calling pg_temp.chk() inside that switched context (scenario 1),
-- so this grant is required or every such call fails with "permission denied for function chk".
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
-- A Google sign-in with no profile yet -- what admin_link_customer_google_account matches against.
-- auth.users.email is deliberately NOT the matched email (@test.invalid, distinct and unique per
-- user) -- only auth.identities.identity_data->>'email' is, matching the migration's comment that
-- the match is against the identity row, never auth.users.email.
create function pg_temp.mkgoogle(p_email text) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_google_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v, v::text, 'google', jsonb_build_object('sub', v::text, 'email', p_email, 'email_verified', true), now(), now(), now());
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_master2 uuid; v_ops uuid; v_tech_profile uuid; v_tech_id uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; c6 uuid; c7 uuid; c8 uuid; c9 uuid;
  g1 uuid; g_dup_a uuid; g_dup_b uuid; g_staff uuid; g_case uuid;
  v_profile record; v_audit record; v_n int;
  rc_before bigint; pc_before bigint; ac_before bigint;
  rc_after bigint; pc_after bigint; ac_after bigint;
begin
  select count(*) into rc_before from public.customers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into pc_before from public.profiles where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into ac_before from public.audit_log where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_admin_link_1') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into public.organizations (name) values ('__TEST_admin_link_2') returning id into v_org2;
  insert into public.settings (org_id) values (v_org2) on conflict (org_id) do nothing;

  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tech_profile := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id) values (v_org, v_tech_profile) returning id into v_tech_id;

  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c1', '9500000001') returning id into c1;
  insert into public.customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ c2', '9500000002', true) returning id into c2;
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c3', '9500000003') returning id into c3;
  update public.customers set primary_profile_id = v_ops where id = c3; -- pre-"linked"
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c4', '9500000004') returning id into c4; -- ambiguous target
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c5', '9500000005') returning id into c5; -- no_matching_signin / not_linked
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c6', '9500000006') returning id into c6; -- staff identity
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c7', '9500000007') returning id into c7; -- case/whitespace
  insert into public.customers (org_id, name, mobile) values (v_org2, '__TEST_ c8', '9500000008') returning id into c8; -- different org
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ c9', '9500000009') returning id into c9; -- relink target, left unlinked

  g1 := pg_temp.mkgoogle('alink1.test@gmail.com');
  g_dup_a := pg_temp.mkgoogle('alink.dup.test@gmail.com');
  g_dup_b := pg_temp.mkgoogle('alink.dup.test@gmail.com');
  -- g_staff's identity belongs to the TECHNICIAN's own auth user, not a fresh mkgoogle() one --
  -- insert it directly against v_tech_profile (no mkgoogle() call here: that would create a
  -- SECOND identity with this same email, making the match ambiguous instead of already-staff).
  g_staff := v_tech_profile;
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v_tech_profile, v_tech_profile::text, 'google', jsonb_build_object('sub', v_tech_profile::text, 'email', 'alink.staff.test@gmail.com', 'email_verified', true), now(), now(), now());
  g_case := pg_temp.mkgoogle('mixedcase.alink.test@gmail.com');

  -- ===== 1. non-master is refused =====
  perform pg_temp.as_user(v_ops);
  begin
    perform public.admin_link_customer_google_account(c1, 'alink1.test@gmail.com');
    perform pg_temp.chk('non-master link refused', false);
  exception when others then
    perform pg_temp.chk('non-master link refused', sqlerrm like '%master role required%', sqlerrm);
  end;
  begin
    perform public.admin_unlink_customer_google_account(c1, 'x');
    perform pg_temp.chk('non-master unlink refused', false);
  exception when others then
    perform pg_temp.chk('non-master unlink refused', sqlerrm like '%master role required%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ===== 2. unauthenticated (auth.uid() null) is refused =====
  begin
    perform public.admin_link_customer_google_account(c1, 'alink1.test@gmail.com');
    perform pg_temp.chk('unauthenticated link refused', false);
  exception when others then
    perform pg_temp.chk('unauthenticated link refused', sqlerrm like '%no authenticated user%', sqlerrm);
  end;

  -- ===== 3. grants =====
  perform pg_temp.chk('anon cannot execute admin_link_customer_google_account',
    not has_function_privilege('anon', 'public.admin_link_customer_google_account(uuid,text)', 'execute'));
  perform pg_temp.chk('authenticated can execute admin_link_customer_google_account',
    has_function_privilege('authenticated', 'public.admin_link_customer_google_account(uuid,text)', 'execute'));
  perform pg_temp.chk('anon cannot execute admin_unlink_customer_google_account',
    not has_function_privilege('anon', 'public.admin_unlink_customer_google_account(uuid,text)', 'execute'));
  perform pg_temp.chk('authenticated can execute admin_unlink_customer_google_account',
    has_function_privilege('authenticated', 'public.admin_unlink_customer_google_account(uuid,text)', 'execute'));

  -- ===== 4. happy path: master links c1 =====
  perform pg_temp.as_user(v_master);
  perform public.admin_link_customer_google_account(c1, 'alink1.test@gmail.com');
  perform pg_temp.as_pg();
  perform pg_temp.chk('c1.primary_profile_id set to g1', (select primary_profile_id from public.customers where id = c1) = g1);
  select * into v_profile from public.profiles where id = g1;
  perform pg_temp.chk('profile created with role=customer, correct org', v_profile.role = 'customer' and v_profile.org_id = v_org);
  select * into v_audit from public.audit_log where table_name = 'customers' and row_id = c1 and action = 'admin_link_google_account' order by created_at desc limit 1;
  perform pg_temp.chk('audit row written for the link', v_audit.id is not null and v_audit.actor_id = v_master and (v_audit.after->>'google_email') = 'alink1.test@gmail.com');

  -- ===== 5. re-linking an already-linked customer is refused =====
  perform pg_temp.as_user(v_master);
  begin
    perform public.admin_link_customer_google_account(c1, 'alink1.test@gmail.com');
    perform pg_temp.chk('re-linking an already-linked customer refused', false);
  exception when others then
    perform pg_temp.chk('re-linking an already-linked customer refused', sqlerrm like '%already_linked%', sqlerrm);
  end;

  -- ===== 6. test customer refused =====
  begin
    perform public.admin_link_customer_google_account(c2, 'anything.test@gmail.com');
    perform pg_temp.chk('test customer link refused', false);
  exception when others then
    perform pg_temp.chk('test customer link refused', sqlerrm like '%test_customer%', sqlerrm);
  end;

  -- ===== 7. a customer pre-linked some other way is refused =====
  begin
    perform public.admin_link_customer_google_account(c3, 'anything.test@gmail.com');
    perform pg_temp.chk('pre-linked customer link refused', false);
  exception when others then
    perform pg_temp.chk('pre-linked customer link refused', sqlerrm like '%already_linked%', sqlerrm);
  end;

  -- ===== 8. no matching sign-in =====
  begin
    perform public.admin_link_customer_google_account(c5, 'no.such.signin.test@gmail.com');
    perform pg_temp.chk('no_matching_signin refused', false);
  exception when others then
    perform pg_temp.chk('no_matching_signin refused', sqlerrm like '%no_matching_signin%', sqlerrm);
  end;

  -- ===== 9. ambiguous email (two identities, same email) =====
  begin
    perform public.admin_link_customer_google_account(c4, 'alink.dup.test@gmail.com');
    perform pg_temp.chk('ambiguous_signin refused', false);
  exception when others then
    perform pg_temp.chk('ambiguous_signin refused', sqlerrm like '%ambiguous_signin%', sqlerrm);
  end;

  -- ===== 10. a staff/technician's own Google sign-in cannot be linked to a customer =====
  begin
    perform public.admin_link_customer_google_account(c6, 'alink.staff.test@gmail.com');
    perform pg_temp.chk('staff/technician sign-in link refused', false);
  exception when others then
    perform pg_temp.chk('staff/technician sign-in link refused', sqlerrm like '%signin_already_linked%', sqlerrm);
  end;

  -- ===== 11. email case/whitespace normalization =====
  perform public.admin_link_customer_google_account(c7, '  MixedCase.ALink.Test@Gmail.COM  ');
  perform pg_temp.chk('case/whitespace-normalized email still matches', (select primary_profile_id from public.customers where id = c7) = g_case);

  -- ===== 12. org mismatch: master in org 1 cannot touch a customer in org 2 =====
  begin
    perform public.admin_link_customer_google_account(c8, 'anything.test@gmail.com');
    perform pg_temp.chk('cross-org customer link refused', false);
  exception when others then
    perform pg_temp.chk('cross-org customer link refused', sqlerrm like '%customer_not_found%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- ===== 13. unlink: reason required =====
  perform pg_temp.as_user(v_master);
  begin
    perform public.admin_unlink_customer_google_account(c1, '');
    perform pg_temp.chk('unlink without reason refused', false);
  exception when others then
    perform pg_temp.chk('unlink without reason refused', sqlerrm like '%reason_required%', sqlerrm);
  end;

  -- ===== 14. unlink: not linked =====
  begin
    perform public.admin_unlink_customer_google_account(c5, 'testing not_linked');
    perform pg_temp.chk('unlinking a not-linked customer refused', false);
  exception when others then
    perform pg_temp.chk('unlinking a not-linked customer refused', sqlerrm like '%not_linked%', sqlerrm);
  end;

  -- ===== 15. unlink: happy path, profile actually deleted =====
  perform public.admin_unlink_customer_google_account(c1, 'linked the wrong test customer');
  perform pg_temp.as_pg();
  perform pg_temp.chk('c1.primary_profile_id cleared', (select primary_profile_id from public.customers where id = c1) is null);
  select count(*) into v_n from public.profiles where id = g1;
  perform pg_temp.chk('g1''s profile row actually deleted (not just unlinked)', v_n = 0);
  select * into v_audit from public.audit_log where table_name = 'customers' and row_id = c1 and action = 'admin_unlink_google_account' order by created_at desc limit 1;
  perform pg_temp.chk('audit row written for the unlink, with reason', v_audit.id is not null and (v_audit.after->>'reason') = 'linked the wrong test customer');

  -- ===== 16. relink after unlink: the freed identity can be linked again (to a different customer) =====
  perform pg_temp.as_user(v_master);
  perform public.admin_link_customer_google_account(c9, 'alink1.test@gmail.com');
  perform pg_temp.as_pg();
  perform pg_temp.chk('unlinked identity can be relinked to a different customer', (select primary_profile_id from public.customers where id = c9) = g1);

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
  v_mig_hash text;
  v_test_hash text;
  v_result text;
  v_org_fp text;
  v_cust_count_before bigint; v_cust_md5_before text;
  v_prof_count_before bigint; v_prof_md5_before text;
  v_audit_count_before bigint; v_audit_md5_before text;
  v_cust_count_after bigint; v_cust_md5_after text;
  v_prof_count_after bigint; v_prof_md5_after text;
  v_audit_count_after bigint; v_audit_md5_after text;
begin
  -- lock budget -- first executed statement, before even the time gate.
  perform set_config('lock_timeout', '5s', true);

  if (clock_timestamp() at time zone 'Asia/Kolkata')::time < time '11:00' then
    raise exception 'rehearsal refused: must run at or after 11:00 IST';
  end if;

  -- organisation fingerprint pin -- right after the time gate, before the sha256 checks.
  select md5(o.id::text || '|' || o.name) into v_org_fp
    from public.organizations o
    where o.name not like '\_\_TEST\_%' escape '\'
    order by o.created_at asc, o.id asc
    limit 1;
  if v_org_fp is distinct from '6f891cf85011f08c2f22fb4a208d21bd' then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- real-org fingerprint of every table these functions can write to, taken before the
  -- migration runs at all.
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

  v_mig_hash := encode(sha256(convert_to(v_migration, 'UTF8')), 'hex');
  v_test_hash := encode(sha256(convert_to(v_test, 'UTF8')), 'hex');

  if v_mig_hash <> '527e0dd1d493145aebb94acd5ebf8ca31647dac43794d751b8cdd39a12ce68e1' then
    raise exception 'migration hash mismatch: expected 527e0dd1d493145aebb94acd5ebf8ca31647dac43794d751b8cdd39a12ce68e1, got %', v_mig_hash;
  end if;
  if v_test_hash <> 'da70e497b81b55a8492cd8765b352d50de2852d951c629b5dfa0c27a6f501090' then
    raise exception 'test hash mismatch: expected da70e497b81b55a8492cd8765b352d50de2852d951c629b5dfa0c27a6f501090, got %', v_test_hash;
  end if;

  execute v_migration;

  begin
    execute v_test;
    v_result := 'RESULTS(test did not raise -- unexpected, treat as FAIL)';
  exception when others then
    v_result := sqlerrm;
  end;

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
$w$;
