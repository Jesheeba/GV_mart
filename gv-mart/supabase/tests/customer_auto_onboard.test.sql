-- Rolled-back DB tests for 20261130100000_customer_auto_onboard_schema.sql +
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

  -- ===== real-data safety net (redundant with the wrapper-level fingerprint, belt and braces) =====
  select count(*) into rc_after from public.customers where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into pc_after from public.profiles where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  select count(*) into ac_after from public.audit_log where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real customers row count unchanged', rc_before = rc_after, format('%s -> %s', rc_before, rc_after));
  perform pg_temp.chk('real profiles row count unchanged', pc_before = pc_after, format('%s -> %s', pc_before, pc_after));
  perform pg_temp.chk('real audit_log row count unchanged', ac_before = ac_after, format('%s -> %s', ac_before, ac_after));

  raise exception E'RESULTS\n%', (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
