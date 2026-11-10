-- Rolled-back DB tests for 20261121100000_admin_link_customer_google_account.sql.
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
