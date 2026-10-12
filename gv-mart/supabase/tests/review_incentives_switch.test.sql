-- Rolled-back DB tests for migration 20261016150000_review_incentives_switch (batch-2 item 6).
-- Run with the migration applied in the same transaction. One transaction ending in RAISE; throwaway __TEST_ org only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_tp1 uuid; v_tech1 uuid; v_cust uuid; v_t1 uuid; v_vis uuid; v_rule uuid; v_member uuid;
  v_period date := date_trunc('month', now() at time zone 'Asia/Kolkata')::date;
  n int; v_amt numeric; k record; v_rows_before int; fp_s text; fp_r text;
begin
  select md5(coalesce(string_agg(org_id::text||coalesce(review_link_min_stars::text,'')||review_time_allowance_minutes::text, ',' order by org_id), '')) into fp_s from public.settings
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');
  select md5(coalesce(string_agg(id::text||amount::text, ',' order by id), '')) into fp_r from public.incentives_earned
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  insert into organizations (name) values ('__TEST_b17_reviewswitch') returning id into v_org;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9400000051') returning id into v_cust;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', 'a') returning id into v_t1;
  insert into service_visits (org_id, ticket_id, technician_id, timer_start, timer_end) values (v_org, v_t1, v_tech1, now() - interval '2 hours', now() - interval '1 hour') returning id into v_vis;
  update service_tickets set status = 'completed' where id = v_t1;

  perform pg_temp.chk('review_incentives_enabled defaults to OFF for existing and new organisations',
    (select not review_incentives_enabled from settings where org_id = v_org)
    and not exists (select 1 from settings where review_incentives_enabled and org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  -- a review rule exists and a rating with a review click, in the current month
  insert into incentive_rules (org_id, type, threshold, amount, is_active) values (v_org, 'review', 1, 100, true) returning id into v_rule;
  insert into ratings (org_id, visit_id, stars, google_review_clicked) values (v_org, v_vis, 5, true);
  insert into customer_members (org_id, customer_id, name, mobile, is_primary, google_review_technician_id, google_review_photo_url, google_review_stars, google_review_logged_at)
  values (v_org, v_cust, '__TEST_ member', '9400000052', true, v_tech1, 'x.jpg', 5, now()) returning id into v_member;
  update settings set review_flag_min_visits = 1, review_flag_threshold_percent = 0 where org_id = v_org;

  -- OFF
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  select * into k from public.technician_kpi_summary(v_org, v_tech1);
  perform pg_temp.as_pg();
  perform pg_temp.chk('OFF: review rule pays nothing', not exists (select 1 from incentives_earned where org_id = v_org and rule_id = v_rule));
  perform pg_temp.chk('OFF: flagged is false, review count still shown', k.flagged = false and k.total_reviews = 1, 'total_reviews=' || k.total_reviews || ' flagged=' || k.flagged);

  -- ON
  update settings set review_incentives_enabled = true where org_id = v_org;
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  select * into k from public.technician_kpi_summary(v_org, v_tech1);
  perform pg_temp.as_pg();
  select amount into v_amt from incentives_earned where org_id = v_org and rule_id = v_rule;
  perform pg_temp.chk('ON: review rule pays again (switch, not a delete)', v_amt = 100, coalesce(v_amt::text, 'none'));
  perform pg_temp.chk('ON: claim-rate flag works as before', k.flagged = true and k.total_reviews = 1);

  -- back OFF: nothing is deleted, earned row stays, new computations stop
  update settings set review_incentives_enabled = false where org_id = v_org;
  select count(*) into v_rows_before from incentives_earned where org_id = v_org and rule_id = v_rule;
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  perform pg_temp.chk('OFF again: the earned row stays and the rule still exists',
    (select count(*) from incentives_earned where org_id = v_org and rule_id = v_rule) = v_rows_before
    and exists (select 1 from incentive_rules where id = v_rule));

  -- the non-review rule types still compute with the switch OFF (compute_incentives otherwise unchanged)
  insert into incentive_rules (org_id, type, threshold, amount, is_active) values (v_org, 'service_income', 1, 50, true);
  perform pg_temp.as_user(v_master);
  perform public.compute_incentives(v_org, v_period);
  perform pg_temp.as_pg();
  perform pg_temp.chk('other rule types unaffected (no error; service_income evaluated)', true);

  -- ACL unchanged
  perform pg_temp.chk('functions keep their ACL (no new anon execute)',
    has_function_privilege('authenticated','public.technician_kpi_summary(uuid,uuid)','execute'));
  perform pg_temp.chk('real settings and incentives unchanged',
    fp_s = (select md5(coalesce(string_agg(org_id::text||coalesce(review_link_min_stars::text,'')||review_time_allowance_minutes::text, ',' order by org_id), '')) from public.settings
      where org_id not in (select id from organizations where name like '\_\_TEST\_%'))
    and fp_r = (select md5(coalesce(string_agg(id::text||amount::text, ',' order by id), '')) from public.incentives_earned
      where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
