-- Rolled-back DB tests for migration 20261016140000_referral_overview_read_model (batch-2 item 4, phase 1, read-only).
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
  v_org uuid; v_org2 uuid; v_master uuid; v_sales uuid; v_ops uuid; v_cust_user uuid; v_tp1 uuid; v_tp2 uuid; v_tech1 uuid; v_tech2 uuid;
  v_c1 uuid; v_c2 uuid; v_c_test uuid; v_l1 uuid; v_l2 uuid; v_l3 uuid; v_l4 uuid; v_l_test uuid;
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_vis uuid; r jsonb; ref jsonb; n int; fp text;
begin
  select md5(coalesce(string_agg(id::text||updated_at::text, ',' order by id), '')) into fp from public.leads
    where org_id not in (select id from organizations where name like '\_\_TEST\_%');

  insert into organizations (name) values ('__TEST_b17_referral1') returning id into v_org;
  insert into organizations (name) values ('__TEST_b17_referral1_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tp1 := pg_temp.mkuser('technician', v_org);
  v_tp2 := pg_temp.mkuser('technician', v_org);
  v_cust_user := pg_temp.mkuser('customer', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp1, true) returning id into v_tech1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp2, true) returning id into v_tech2;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Referred A', '9400000041') returning id into v_c1;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ Referred B', '9400000042') returning id into v_c2;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ Flagged', '9400000043', true) returning id into v_c_test;

  -- customer A referred by technician 1 TWICE (two leads), customer B referred by technician 2, flagged customer by technician 1
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c1, '__TEST_ A first', 'referral', 'won', v_tech1) returning id into v_l1;
  insert into lead_activities (org_id, lead_id, type, note) values (v_org, v_l1, 'converted', 'Walk-in sale, referred by technician');
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c1, '__TEST_ A second', 'referral', 'won', v_tech1) returning id into v_l2;
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c2, '__TEST_ B', 'referral', 'won', v_tech2) returning id into v_l3;
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c_test, '__TEST_ flagged', 'referral', 'won', v_tech1) returning id into v_l_test;
  -- a non-referral lead owned by technician 1 must not show
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c2, '__TEST_ field', 'field', 'new', v_tech1) returning id into v_l4;

  -- tickets: A: installation (from the first lead, completed), then an AMC visit (second lead, open)
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, lead_id, status) values (v_org, v_c1, 'installation', 'inst', v_l1, 'open') returning id into v_t1;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, lead_id, status) values (v_org, v_c1, 'amc', 'amc visit', v_l2, 'open') returning id into v_t2;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, lead_id, status) values (v_org, v_c2, 'paid', 'repair', v_l3, 'open') returning id into v_t3;
  insert into service_visits (org_id, ticket_id, technician_id, timer_start, timer_end) values (v_org, v_t1, v_tech1, now() - interval '3 hours', now() - interval '2 hours') returning id into v_vis;
  update service_tickets set status = 'completed' where id = v_t1;

  -- ACL
  perform pg_temp.chk('referral_overview: authenticated yes, anon/PUBLIC no',
    has_function_privilege('authenticated','public.referral_overview(uuid)','execute') and not has_function_privilege('anon','public.referral_overview(uuid)','execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.proname='referral_overview' and a.grantee = 0));
  perform pg_temp.chk('view: not readable by anon', not has_table_privilege('anon','public.v_referral_events','select'));

  -- master sees the organisation
  perform pg_temp.as_user(v_master);
  r := public.referral_overview(null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('two referral records (one per customer+technician; flagged customer excluded)', jsonb_array_length(r -> 'referrals') = 2, (r -> 'summary')::text);
  select e into ref from jsonb_array_elements(r -> 'referrals') e where (e ->> 'customer_id')::uuid = v_c1;
  perform pg_temp.chk('customer A: one record despite two referral leads', (ref ->> 'lead_count')::int = 2 and (ref ->> 'referral_id')::uuid in (v_l1, v_l2), ref ->> 'lead_count');
  perform pg_temp.chk('who referred whom is named', ref ->> 'referrer_name' = '__TEST_ technician' and ref ->> 'customer_name' = '__TEST_ Referred A');
  perform pg_temp.chk('origin note comes from the converted activity', ref ->> 'origin_note' = 'Walk-in sale, referred by technician');
  perform pg_temp.chk('status completed and the first completed ticket is the installation', ref ->> 'status' = 'completed' and (ref ->> 'first_completed_ticket_id')::uuid = v_t1);
  perform pg_temp.chk('both tickets listed as events; only the first completed earns the bonus',
    jsonb_array_length(ref -> 'events') = 2
    and (select count(*) from jsonb_array_elements(ref -> 'events') ev where (ev ->> 'earns_bonus')::boolean) = 1
    and (select (ev ->> 'earns_bonus')::boolean from jsonb_array_elements(ref -> 'events') ev where (ev ->> 'ticket_id')::uuid = v_t1));
  perform pg_temp.chk('bonus is reported as not configured (nothing invented)', ref -> 'bonus' ->> 'state' = 'not_configured' and (ref -> 'bonus' -> 'amount') = 'null'::jsonb and ref -> 'bonus' ->> 'earned_at' is not null);
  select e into ref from jsonb_array_elements(r -> 'referrals') e where (e ->> 'customer_id')::uuid = v_c2;
  perform pg_temp.chk('customer B: in progress (ticket open), no bonus date', ref ->> 'status' = 'in_progress' and ref -> 'bonus' ->> 'earned_at' is null);
  perform pg_temp.chk('field lead is not a referral', not exists (select 1 from jsonb_array_elements(r -> 'referrals') e where e ->> 'referral_id' = v_l4::text));

  -- filter by technician
  perform pg_temp.as_user(v_sales);
  r := public.referral_overview(v_tech2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales staff may filter by technician', jsonb_array_length(r -> 'referrals') = 1 and (r -> 'referrals' -> 0 ->> 'customer_id')::uuid = v_c2);
  perform pg_temp.as_user(v_ops);
  perform pg_temp.chk('operation admin may read', jsonb_array_length((public.referral_overview(null)) -> 'referrals') = 2);

  -- technicians only see their own, whatever they ask for
  perform pg_temp.as_user(v_tp2);
  r := public.referral_overview(v_tech1);
  perform pg_temp.chk('technician 2 asking for technician 1 gets only their own', jsonb_array_length(r -> 'referrals') = 1 and (r -> 'referrals' -> 0 ->> 'referrer_technician_id')::uuid = v_tech2);
  perform pg_temp.as_user(v_tp1);
  r := public.referral_overview(null);
  perform pg_temp.chk('technician 1 sees only own referral (customer A)', jsonb_array_length(r -> 'referrals') = 1 and (r -> 'referrals' -> 0 ->> 'customer_id')::uuid = v_c1);

  -- customers are refused
  perform pg_temp.as_user(v_cust_user);
  begin
    perform public.referral_overview(null);
    perform pg_temp.chk('customer role refused', false);
  exception when others then
    perform pg_temp.chk('customer role refused', sqlerrm like '%not allowed%', sqlerrm);
  end;
  perform pg_temp.as_pg();

  -- nothing written
  perform pg_temp.chk('real leads untouched', fp = (select md5(coalesce(string_agg(id::text||updated_at::text, ',' order by id), '')) from public.leads
    where org_id not in (select id from organizations where name like '\_\_TEST\_%')));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
