-- Rolled-back DB tests for 20270101100200_rework_penalty_salary.sql (feature doc build-docs/features/rework.md, AC5).
-- Preconditions: 20261229100000 committed and 20270101100100 applied (or concatenated ahead). The runner puts the
-- penalty migration in front of this file in ONE transaction; this file ends in RAISE so everything rolls back.
-- Synthetic __TEST_ org and LAST month only - never the real org, never the real current month.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.try_as(p_uid uuid, p_sql text) returns text language plpgsql as $f$
begin
  perform pg_temp.as_user(p_uid);
  begin
    execute p_sql;
  exception when others then
    perform pg_temp.as_pg();
    return sqlerrm;
  end;
  perform pg_temp.as_pg();
  return '';
end $f$;
-- A finished rework ticket in the given month (inserted as postgres: the guard trigger allows the owner).
create function pg_temp.mkrework(p_org uuid, p_cust uuid, p_tech uuid, p_outcome text, p_at timestamptz) returns uuid language plpgsql as $f$
declare v_inv uuid; v_tk uuid;
begin
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at, updated_at)
    values (p_org, p_cust, 'spare', 0, 0, 0, 0, 'paid', 0, p_at, p_at) returning id into v_inv;
  insert into public.service_tickets (org_id, customer_id, type, status, name_of_complaint, invoice_id, rework_responsible_technician_id, rework_outcome, rework_raised_at)
    values (p_org, p_cust, 'rework', 'completed', '__TEST_ rework', v_inv, p_tech, p_outcome, p_at) returning id into v_tk;
  return v_tk;
end $f$;
create function pg_temp.salary(p_master uuid, p_org uuid, p_tech uuid, p_period date) returns public.salaries language plpgsql as $f$
declare v public.salaries;
begin
  perform pg_temp.as_user(p_master);
  v := public.compute_salary(p_org, p_tech, p_period);
  perform pg_temp.as_pg();
  return v;
end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_ops uuid; v_tp uuid; v_tech uuid; v_cust uuid; v_test_cust uuid;
  v_period date := date_trunc('month', (now() at time zone 'Asia/Kolkata') - interval '1 month')::date;
  v_at timestamptz := (date_trunc('month', (now() at time zone 'Asia/Kolkata') - interval '1 month') + interval '10 days') at time zone 'Asia/Kolkata';
  v_s public.salaries; v_base_net numeric; v_err text; v_cnt integer; v_adj uuid;
  fp_before text; fp_after text;
begin
  select md5(coalesce(string_agg(id::text || net::text, ',' order by id), '')) into fp_before from public.salaries
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');

  insert into public.organizations (name) values ('__TEST_rework_penalty') returning id into v_org;
  insert into public.settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into public.technician_tiers (org_id, name, rank, monthly_salary) values (v_org, '__TEST_ Tier', 1, 15000);
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  insert into public.technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;
  insert into public.customers (org_id, name, mobile) values (v_org, '__TEST_ Cust', '9500000081') returning id into v_cust;
  insert into public.customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ TestCust', '9500000082', true) returning id into v_test_cust;

  -- 4 counted free reworks last month; plus 1 rework-paid, 1 test-customer, 1 from this month: none of those count.
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'free', v_at);
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'free', v_at);
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'free', v_at);
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'free', v_at);
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'paid', v_at);
  perform pg_temp.mkrework(v_org, v_test_cust, v_tech, 'free', v_at);
  perform pg_temp.mkrework(v_org, v_cust, v_tech, 'free', now());
  perform pg_temp.chk('fixture: 4 counted reworks last month', public.technician_rework_count(v_org, v_tech, v_period) = 4,
    public.technician_rework_count(v_org, v_tech, v_period)::text);

  -- ── penalty off (X/Y not set) ──────────────────────────────────────────────────────────────
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  v_base_net := v_s.net;
  perform pg_temp.chk('X/Y not set -> no rework deduction', v_s.rework_deduction = 0 and v_s.rework_count = 4, format('%s/%s', v_s.rework_deduction, v_s.rework_count));

  -- ── P2: every rework after the Xth costs Y ──────────────────────────────────────────────────
  update public.settings set rework_penalty_free_count = 2, rework_penalty_amount = 200 where org_id = v_org;
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('X=2 Y=200, 4 reworks -> 400 deducted', v_s.rework_deduction = 400, v_s.rework_deduction::text);
  perform pg_temp.chk('net drops by exactly the deduction', v_s.net = v_base_net - 400, format('%s vs %s', v_s.net, v_base_net));
  update public.settings set rework_penalty_free_count = 4 where org_id = v_org;
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('X=4, 4 reworks -> 0 (limit not passed)', v_s.rework_deduction = 0, v_s.rework_deduction::text);
  update public.settings set rework_penalty_free_count = 3 where org_id = v_org;
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('X=3, 4 reworks -> 200 (one after the limit)', v_s.rework_deduction = 200, v_s.rework_deduction::text);
  update public.settings set rework_penalty_free_count = 0 where org_id = v_org;
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('X=0, 4 reworks -> 800', v_s.rework_deduction = 800, v_s.rework_deduction::text);

  -- ── master omits / adds deductions ─────────────────────────────────────────────────────────
  perform pg_temp.as_user(v_master);
  insert into public.monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tp, v_period, 'rework_deduction', 'exclude', null, 'Omitted for this month') returning id into v_adj;
  perform pg_temp.as_pg();
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('master exclude -> rework deduction omitted', v_s.rework_deduction = 0 and v_s.net = v_base_net, v_s.rework_deduction::text);

  perform pg_temp.as_user(v_master);
  delete from public.monthly_adjustments where id = v_adj;
  get diagnostics v_cnt = row_count;
  perform pg_temp.as_pg();
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('master removes the exclude -> deduction back', v_cnt = 1 and v_s.rework_deduction = 800, format('%s rows, %s', v_cnt, v_s.rework_deduction));

  perform pg_temp.as_user(v_master);
  insert into public.monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tp, v_period, 'late_deduction', 'top_up', 50, 'Added late deduction');
  perform pg_temp.as_pg();
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('master top_up on late deduction adds 50', v_s.late_deduction = 50, v_s.late_deduction::text);
  perform pg_temp.as_user(v_master);
  insert into public.monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason)
    values (v_org, v_tp, v_period, 'rework_deduction', 'top_up', 100, 'Added rework deduction');
  perform pg_temp.as_pg();
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('master top_up on rework deduction adds 100', v_s.rework_deduction = 900, v_s.rework_deduction::text);

  -- ── only the master touches deduction rows ─────────────────────────────────────────────────
  v_err := pg_temp.try_as(v_ops, format('insert into public.monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason) values (%L, %L, %L, %L, %L, null, %L)',
    v_org, v_tp, v_period, 'rework_deduction', 'exclude', 'ops try'));
  perform pg_temp.chk('operation_admin cannot omit a deduction', v_err like '%row-level security%', v_err);
  v_err := pg_temp.try_as(v_ops, format('insert into public.monthly_adjustments (org_id, profile_id, period, adjustment_target, adjustment_type, amount, reason) values (%L, %L, %L, %L, %L, null, %L)',
    v_org, v_tp, v_period, 'recharge', 'exclude', 'ops recharge still fine'));
  perform pg_temp.chk('operation_admin can still exclude recharge (unchanged)', v_err = '', v_err);
  perform pg_temp.as_user(v_ops);
  delete from public.monthly_adjustments where org_id = v_org and adjustment_target = 'rework_deduction';
  get diagnostics v_cnt = row_count;
  perform pg_temp.as_pg();
  perform pg_temp.chk('operation_admin cannot remove deduction rows', v_cnt = 0, v_cnt::text);
  perform pg_temp.as_user(v_master);
  delete from public.monthly_adjustments where org_id = v_org and adjustment_target = 'recharge';
  get diagnostics v_cnt = row_count;
  perform pg_temp.as_pg();
  perform pg_temp.chk('even the master cannot delete recharge rows (unchanged)', v_cnt = 0, v_cnt::text);

  -- ── floor still holds ──────────────────────────────────────────────────────────────────────
  update public.settings set rework_penalty_amount = 100000 where org_id = v_org;
  v_s := pg_temp.salary(v_master, v_org, v_tech, v_period);
  perform pg_temp.chk('huge penalty -> net floored at 0 and the shortfall recorded', v_s.net = 0 and v_s.shortfall_amount > 0, format('%s / %s', v_s.net, v_s.shortfall_amount));

  perform pg_temp.chk('compute_salary keeps authenticated EXECUTE, no anon',
    has_function_privilege('authenticated', 'public.compute_salary(uuid,uuid,date)', 'execute')
    and not has_function_privilege('anon', 'public.compute_salary(uuid,uuid,date)', 'execute'));

  select md5(coalesce(string_agg(id::text || net::text, ',' order by id), '')) into fp_after from public.salaries
    where org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
  perform pg_temp.chk('real salaries unchanged', fp_before = fp_after);

  raise exception 'RESULTS%', E'\n' || (select string_agg(r.line, E'\n' order by r.n) from pg_temp.res r);
end $t$;
