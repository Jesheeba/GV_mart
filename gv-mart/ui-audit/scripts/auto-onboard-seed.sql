-- Manual seed for the 3 auto-onboard Playwright scripts (auto-onboard-*.mjs). NOT part of the
-- build, NOT run automatically by anything. Run by hand via run_rehearsal.mjs against a
-- dev/staging project before running the scripts, then run auto-onboard-cleanup.sql after.
--
-- Creates three REAL (persisted) rows in a throwaway __TEST_ organisation:
--   - a Google identity with no matching customer       -> onboard-new.test@gvmart.invalid
--   - an existing, unlinked customer with a matching    -> onboard-existing.test@gvmart.invalid
--     email, plus the Google identity that should link
--     to it
--   - two existing customers sharing one email           -> onboard-ambiguous.test@gvmart.invalid
--     (ambiguous), plus the Google identity for it
--
-- These are ordinary rows (not wrapped in a rolled-back DO block) -- this file is meant to
-- persist, on purpose, so the Playwright scripts have something real to sign in against.
do $seed$
declare
  v_org uuid;
  v_new uuid;
  v_existing_cust uuid;
  v_existing_user uuid;
  v_ambig_cust_a uuid;
  v_ambig_cust_b uuid;
  v_ambig_user uuid;
begin
  insert into public.organizations (name) values ('__TEST_auto_onboard_pw') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;

  -- Scenario A: brand-new Google user, zero matches.
  v_new := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_new, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'onboard-new.test@gvmart.invalid', 'x', now(), now(), now(), '{}', jsonb_build_object('full_name', 'Playwright New Customer'));
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v_new, v_new::text, 'google', jsonb_build_object('sub', v_new::text, 'email', 'onboard-new.test@gvmart.invalid', 'full_name', 'Playwright New Customer', 'email_verified', true), now(), now(), now());

  -- Scenario B: one existing, unlinked customer with a matching email.
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ existing', '9500000201', 'onboard-existing.test@gvmart.invalid') returning id into v_existing_cust;
  v_existing_user := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_existing_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'onboard-existing.test@gvmart.invalid', 'x', now(), now(), now(), '{}', jsonb_build_object('full_name', 'Playwright Existing Customer'));
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v_existing_user, v_existing_user::text, 'google', jsonb_build_object('sub', v_existing_user::text, 'email', 'onboard-existing.test@gvmart.invalid', 'full_name', 'Playwright Existing Customer', 'email_verified', true), now(), now(), now());

  -- Scenario C: two existing customers sharing one email (ambiguous).
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ ambig a', '9500000202', 'onboard-ambiguous.test@gvmart.invalid') returning id into v_ambig_cust_a;
  insert into public.customers (org_id, name, mobile, email) values (v_org, '__TEST_ ambig b', '9500000203', 'onboard-ambiguous.test@gvmart.invalid') returning id into v_ambig_cust_b;
  v_ambig_user := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v_ambig_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'onboard-ambiguous.test@gvmart.invalid', 'x', now(), now(), now(), '{}', jsonb_build_object('full_name', 'Playwright Ambiguous Customer'));
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
  values (gen_random_uuid(), v_ambig_user, v_ambig_user::text, 'google', jsonb_build_object('sub', v_ambig_user::text, 'email', 'onboard-ambiguous.test@gvmart.invalid', 'full_name', 'Playwright Ambiguous Customer', 'email_verified', true), now(), now(), now());

  raise notice 'seeded org=%, new_user=%, existing_customer=%/existing_user=%, ambiguous_customers=%,%/ambiguous_user=%',
    v_org, v_new, v_existing_cust, v_existing_user, v_ambig_cust_a, v_ambig_cust_b, v_ambig_user;
end
$seed$;
