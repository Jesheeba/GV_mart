-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): standard minutes + efficiency (P5): migration 20261105100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   2cb7679f1e09cdd9f90347165366d23b28cb4c80dd3bfb576468116e0e1b3bb9  gv-mart/supabase/migrations/20261105100000_standard_minutes_and_efficiency.sql
--   226a9cad0c1b5d13c193ccbdca92c21b57622676a9ffb7a366cf89c537dcbb00  gv-mart/supabase/tests/standard_minutes_and_efficiency.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- P5: a standard-minutes master per service (complaint) type; an actual-vs-standard efficiency figure on the
-- technician performance report; the overrun buffer and the ops-resolution SLA move from hard-coded constants to
-- settings. INFORMATIONAL ONLY: nothing here is read by compute_incentives, technician_kpi_summary's "flagged"
-- logic, or any review column — see the standing instruction this package was built under.
--
-- 1. complaint_types.standard_minutes: nullable, master-edited in Masters > Complaint Types (ComplaintTypesTab.tsx,
--    which already master-gates writes via complaint_types_write_master — no RLS change). Per-ITEM standard times
--    (products.standard_time_minutes, spares.standard_time_minutes, 20260725100000) and the four per-TICKET-TYPE
--    defaults (settings.default_duration_*, 20260721090000) already existed; this is the finer-grained master the
--    audit found missing — per complaint type, not just per paid/warranty/amc/installation.
--
-- 2. settings.job_overrun_buffer_minutes (was the OVERRUN_BUFFER_MINUTES=5 constant in src/lib/job-overrun.ts) and
--    settings.ops_resolution_sla_hours (was the hard-coded `interval '24 hours'` inside report_ops_resolution).
--    report_ops_resolution is redefined with the SAME signature and return shape — its two existing SQL callers
--    (report_kpi_tiles, the amc-visits migration) are untouched; only its body now reads settings instead of a
--    literal. Default 24 preserves today's behaviour exactly until master changes it in Settings.
--
-- 3. report_performance_efficiency(p_from, p_to): a NEW, separate RPC — report_performance itself is NOT edited.
--    For each technician's timed visits in range (same population as report_performance's own `jobsDone`/
--    `avgCompletionMinutes`: org-scoped, not public._visit_is_test(sv.id), timer_start in range — matched against
--    report_performance's LATEST body in 20261016110000_test_customer_flag.sql, not the earlier
--    20261009120000 copy, which predates the test-customer exclusion), sums actual minutes (timer_end -
--    timer_start) against a resolved "standard" minutes figure (the ticket's complaint_types.standard_minutes if
--    set, else the ticket type's settings.default_duration_* default) and returns a percentage. A visit whose
--    standard cannot be resolved at all is excluded from BOTH sums, not counted as 0 — it would otherwise
--    silently drag the percentage down for a technician who did nothing wrong.

alter table public.complaint_types
  add column standard_minutes integer check (standard_minutes is null or standard_minutes > 0);

alter table public.settings
  add column job_overrun_buffer_minutes integer not null default 5 check (job_overrun_buffer_minutes >= 0),
  add column ops_resolution_sla_hours integer not null default 24 check (ops_resolution_sla_hours > 0);

comment on column public.settings.job_overrun_buffer_minutes is
  'Minutes of grace after a job''s allowed duration before the overrun alert fires (lib/job-overrun.ts). Was a hard-coded constant.';
comment on column public.settings.ops_resolution_sla_hours is
  'Hours within which a completed ticket counts as "resolved on time" for the ops-resolution KPI. Was a hard-coded 24h.';

-- Same signature and return shape as the existing definition; only the literal `interval '24 hours'` becomes a
-- per-org setting. report_kpi_tiles and the amc-visits migration call this by name with no argument change needed.
create or replace function public.report_ops_resolution(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_sla_hours integer;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_ops_resolution: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);
  select coalesce(s.ops_resolution_sla_hours, 24) into v_sla_hours from public.settings s where s.org_id = v_org;
  v_sla_hours := coalesce(v_sla_hours, 24);

  select jsonb_build_object(
    'resolved_within_24h', count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval),
    'total_completed', count(*),
    'percent', case when count(*) > 0 then round(count(*) filter (where t.updated_at - t.created_at <= (v_sla_hours || ' hours')::interval) * 100.0 / count(*), 1) end
  ) into v_result
  from public.service_tickets t
  where t.org_id = v_org and not public.is_test_customer(t.customer_id) and t.status = 'completed' and t.created_at >= v_from and t.created_at < v_to;
  return v_result;
end;
$$;

create or replace function public.report_performance_efficiency(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_performance_efficiency: p_from and p_to are required';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  with vis as (
    select sv.technician_id,
           greatest(0, round(extract(epoch from (sv.timer_end - sv.timer_start)) / 60)) as actual_minutes,
           coalesce(
             ct.standard_minutes,
             case st.type
               when 'paid' then s.default_duration_paid_minutes
               when 'warranty' then s.default_duration_warranty_minutes
               when 'amc' then s.default_duration_amc_minutes
               when 'installation' then s.default_duration_installation_minutes
             end
           ) as standard_minutes
    from public.service_visits sv
    join public.service_tickets st on st.id = sv.ticket_id
    join public.settings s on s.org_id = v_org
    left join public.complaint_types ct on ct.id = st.complaint_type_id
    where sv.org_id = v_org and not public._visit_is_test(sv.id) and sv.timer_start >= v_from and sv.timer_start < v_to
      and sv.timer_start is not null and sv.timer_end is not null
  ),
  agg as (
    select technician_id, sum(standard_minutes) as std_sum, sum(actual_minutes) as act_sum, count(*) as n
    from vis
    where standard_minutes is not null
    group by technician_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', a.technician_id,
      'efficiency_percent', case when a.act_sum > 0 then round(a.std_sum * 100.0 / a.act_sum, 1) end,
      'efficiency_sample_count', a.n
    )), '[]'::jsonb)
  into v_result
  from agg a;
  return v_result;
end;
$$;
revoke all on function public.report_performance_efficiency(date, date) from public, anon;
grant execute on function public.report_performance_efficiency(date, date) to authenticated;
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '2cb7679f1e09cdd9f90347165366d23b28cb4c80dd3bfb576468116e0e1b3bb9' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261105100000_standard_minutes_and_efficiency.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- Rolled-back DB tests for 20261105100000_standard_minutes_and_efficiency (P5).
-- NOT RUN (written for review). Run only through the rehearsal wrapper: it applies the migration and then this file in ONE
-- request; this file ends in an unconditional RAISE, so nothing is committed. Throwaway __TEST_ organisation only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
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
    (select (x->>'efficiency_percent')::numeric = 66.7 and (x->>'efficiency_sample_count')::int = 2
       from jsonb_array_elements(r) x where x->>'id' = v_tech1::text),
    r::text);
  -- t2: standard 45 (vis3, paid default) ; actual 90 -> 50.0
  perform pg_temp.chk('E3 t2''s efficiency is 45/90 = 50.0% over 1 sample',
    (select (x->>'efficiency_percent')::numeric = 50.0 and (x->>'efficiency_sample_count')::int = 1
       from jsonb_array_elements(r) x where x->>'id' = v_tech2::text),
    r::text);
  perform pg_temp.chk('E4 the test customer''s visit contributed to neither technician''s sample count',
    not exists (select 1 from jsonb_array_elements(r) x where (x->>'efficiency_sample_count')::int > 2));

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

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '226a9cad0c1b5d13c193ccbdca92c21b57622676a9ffb7a366cf89c537dcbb00' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for standard_minutes_and_efficiency.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
