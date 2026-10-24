-- Rolled-back DB tests for 20261024120000_standard_minutes_and_efficiency (P5).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
-- 20261024100000 (applied live) runs `alter default privileges for role postgres revoke execute on functions from public`, globally. That also
-- removes PUBLIC execute from the helper functions below, which live in pg_temp and are called after `set local role authenticated`. This default
-- makes every function created here executable again, including helpers added later. (pg_temp is not a name ALTER DEFAULT PRIVILEGES accepts, so
-- the session's real temporary schema is looked up. The setting is rolled back with the wrapper, and disappears with the session otherwise.)
do $g$ begin execute format('alter default privileges in schema %s grant execute on functions to public', pg_my_temp_schema()::regnamespace); end $g$;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid, p_tech boolean default false) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  if p_tech then insert into public.technicians (org_id, profile_id, is_active) values (p_org, v, true); end if;
  return v;
end $f$;
create function pg_temp.act(p_uid uuid, p_sql text) returns text language plpgsql as $f$
declare n int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute p_sql;
    get diagnostics n = row_count;
    execute 'reset role';
    return 'ok:' || n;
  exception when others then
    execute 'reset role';
    return 'err:' || sqlerrm;
  end;
end $f$;
create function pg_temp.call_as(p_uid uuid, p_fn text, p_from date, p_to date) returns jsonb language plpgsql as $f$
declare v_result jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute format('select public.%I($1, $2)', p_fn) into v_result using p_from, p_to;
  execute 'reset role';
  return v_result;
exception when others then
  execute 'reset role';
  return jsonb_build_object('__error', sqlerrm);
end $f$;

do $t$
declare
  v_org uuid; m uuid; t1 uuid; t2 uuid;
  v_brand uuid; v_model uuid; v_product uuid; v_cust uuid; v_cust_test uuid;
  v_ct_fast uuid; v_tk1 uuid; v_tk2 uuid; v_tk3 uuid; v_tk_test uuid; v_tech1 uuid; v_tech2 uuid;
  v_vis1 uuid; v_vis2 uuid; v_vis3 uuid; v_vis_test uuid;
  x text; r jsonb; v_from date := current_date - 1; v_to date := current_date + 1;
  v_now timestamptz := now();
begin
  insert into public.organizations(name) values ('__TEST_p5') returning id into v_org;
  insert into public.settings(org_id) values (v_org) on conflict do nothing;
  m := pg_temp.mkuser('master', v_org);
  t1 := pg_temp.mkuser('technician', v_org, true); t2 := pg_temp.mkuser('technician', v_org, true);
  select id into v_tech1 from public.technicians where profile_id = t1;
  select id into v_tech2 from public.technicians where profile_id = t2;

  -- C: columns
  perform pg_temp.chk('C1 complaint_types.standard_minutes exists (nullable int, > 0 check)',
    (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'complaint_types' and column_name = 'standard_minutes') = 'integer');
  perform pg_temp.chk('C2 settings has job_overrun_buffer_minutes (default 5) and ops_resolution_sla_hours (default 24)',
    (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'job_overrun_buffer_minutes') = '5'
    and (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'ops_resolution_sla_hours') = '24');
  perform pg_temp.chk('C3 existing settings rows got the default (no backfill needed to reach it)',
    (select ops_resolution_sla_hours = 24 and job_overrun_buffer_minutes = 5 from public.settings where org_id = v_org));

  -- MASTER: complaint type standard minutes, master-write only
  insert into public.complaint_types(org_id, product_category, label) values (v_org, 'ro', '__TEST_fast_fix') returning id into v_ct_fast;
  x := pg_temp.act(m, format('update public.complaint_types set standard_minutes = 20 where id = %L', v_ct_fast));
  perform pg_temp.chk('M1 master sets a complaint type''s standard minutes', x = 'ok:1', x);
  x := pg_temp.act(t1, format('update public.complaint_types set standard_minutes = 999 where id = %L', v_ct_fast));
  perform pg_temp.chk('M2 a technician cannot (complaint_types_write_master, unchanged)', x = 'ok:0' or x like 'err:%', x);
  x := pg_temp.act(m, format('insert into public.complaint_types(org_id, product_category, label, standard_minutes) values (%L, ''ro'', ''__TEST_bad'', -5)', v_org));
  perform pg_temp.chk('M3 a non-positive standard_minutes is refused', x like 'err:%', x);

  -- fixtures for the efficiency RPC
  insert into public.customers(org_id, name, mobile) values (v_org, '__TEST_cust', '9000000010') returning id into v_cust;
  insert into public.customers(org_id, name, mobile, is_test) values (v_org, '__TEST_cust_test', '9000000011', true) returning id into v_cust_test;
  insert into public.brands(org_id, name, category) values (v_org, '__TEST_brand', 'ro') returning id into v_brand;
  insert into public.models(org_id, brand_id, name) values (v_org, v_brand, '__TEST_model') returning id into v_model;

  -- ticket 1: complaint type with standard_minutes=20, technician t1 takes 30 actual minutes -> below standard
  insert into public.service_tickets(org_id, customer_id, type, complaint_type_id, name_of_complaint) values (v_org, v_cust, 'paid', v_ct_fast, '__TEST_t1') returning id into v_tk1;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk1, v_tech1, v_now, v_now + interval '30 minutes') returning id into v_vis1;

  -- ticket 2: no complaint_type_id, type='amc' -> falls back to settings.default_duration_amc_minutes (30);
  -- technician t1, actual 45 minutes
  insert into public.service_tickets(org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'amc', '__TEST_t2') returning id into v_tk2;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk2, v_tech1, v_now, v_now + interval '45 minutes') returning id into v_vis2;

  -- ticket 3: a complaint type with NO standard_minutes set, no fallback applicable other than its own type default;
  -- give it type 'paid' (default 45) so it still resolves — this one is just a second, independent sample for t2.
  insert into public.service_tickets(org_id, customer_id, type, name_of_complaint) values (v_org, v_cust, 'paid', '__TEST_t3') returning id into v_tk3;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk3, v_tech2, v_now, v_now + interval '90 minutes') returning id into v_vis3;

  -- a test-customer's visit must be excluded entirely (same population as report_performance)
  insert into public.service_tickets(org_id, customer_id, type, complaint_type_id, name_of_complaint) values (v_org, v_cust_test, 'paid', v_ct_fast, '__TEST_test_customer') returning id into v_tk_test;
  insert into public.service_visits(org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_tk_test, v_tech1, v_now, v_now + interval '5 minutes') returning id into v_vis_test;

  r := pg_temp.call_as(m, 'report_performance_efficiency', v_from, v_to);
  perform pg_temp.chk('E1 the RPC returns without error for master', not (r ? '__error'), r::text);

  -- t1: standard 20 (vis1) + 30 (vis2, amc default) = 50; actual 30 + 45 = 75 -> 50*100/75 = 66.7
  perform pg_temp.chk('E2 t1''s efficiency is (20+30)/(30+45) = 66.7% over 2 samples, the test-customer visit excluded',
    (select (e->>'efficiency_percent')::numeric = 66.7 and (e->>'efficiency_sample_count')::int = 2
       from jsonb_array_elements(r) e where e->>'id' = v_tech1::text),
    r::text);
  -- t2: standard 45 (vis3, paid default) ; actual 90 -> 50.0
  perform pg_temp.chk('E3 t2''s efficiency is 45/90 = 50.0% over 1 sample',
    (select (e->>'efficiency_percent')::numeric = 50.0 and (e->>'efficiency_sample_count')::int = 1
       from jsonb_array_elements(r) e where e->>'id' = v_tech2::text),
    r::text);
  perform pg_temp.chk('E4 the test customer''s visit contributed to neither technician''s sample count',
    not exists (select 1 from jsonb_array_elements(r) e where (e->>'efficiency_sample_count')::int > 2));

  x := pg_temp.act(t1, format('select public.report_performance_efficiency(%L, %L)', v_from, v_to));
  perform pg_temp.chk('E5 a technician cannot call it (is_staff()-gated via _report_org, same as every other report RPC)',
    x like '%not permitted%' or x like 'err:%', x);
  perform pg_temp.chk('E6 the function is not callable by anon or PUBLIC',
    not has_function_privilege('anon', 'public.report_performance_efficiency(date,date)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                     where p.pronamespace = 'public'::regnamespace and p.proname = 'report_performance_efficiency' and a.grantee = 0));

  -- SLA setting actually changes report_ops_resolution's behaviour (same signature, same shape, no caller change)
  update public.settings set ops_resolution_sla_hours = 1 where org_id = v_org;
  update public.service_tickets set status = 'completed', created_at = now() - interval '2 hours', updated_at = now() where id = v_tk1;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S1 with a 1-hour SLA, a ticket completed 2 hours after creation is NOT within SLA',
    (r->>'resolved_within_24h')::int = 0, r::text);
  update public.settings set ops_resolution_sla_hours = 24 where org_id = v_org;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S2 reverting to the 24h default, the same ticket IS within SLA again',
    (r->>'resolved_within_24h')::int = 1, r::text);

  -- S3/S4 (review fix): the RPC's key is still literally named 'resolved_within_24h' even though the window is
  -- configurable, so it now ALSO carries the real value as 'sla_hours' — an honest label can be built from that,
  -- without guessing 24. Prove the carried value actually reflects a non-default setting, not just the default.
  update public.settings set ops_resolution_sla_hours = 6 where org_id = v_org;
  r := pg_temp.call_as(m, 'report_ops_resolution', v_from, v_to);
  perform pg_temp.chk('S3 report_ops_resolution carries the real sla_hours (6, not the 24 default) in its payload',
    (r->>'sla_hours')::int = 6, r::text);

  r := pg_temp.call_as(m, 'report_kpi_tiles', v_from, v_to);
  perform pg_temp.chk('S4 report_kpi_tiles forwards the SAME sla_hours into its own tile-13 sub-object (additive; every other field of that object is untouched)',
    (r #>> '{service,resolved_within_24h,sla_hours}')::int = 6
    and (r #>> '{service,resolved_within_24h,percent}') is not null,
    r::text);
  update public.settings set ops_resolution_sla_hours = 24 where org_id = v_org;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
