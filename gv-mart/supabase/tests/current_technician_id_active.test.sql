-- DB tests for 20261101110000_current_technician_id_active. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisation only.
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
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
create function pg_temp.mk(p_org uuid, p_assignee uuid, p_by uuid, p_ref text default null, p_ref_id uuid default null) returns uuid language plpgsql as $f$
declare t uuid;
begin
  insert into public.tasks (org_id, assignee_id, assigned_by, title, ref_type, ref_id, source) values (p_org, p_assignee, p_by, '__TEST_ task', p_ref, p_ref_id, 'assigned') returning id into t;
  return t;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_tp uuid; v_tech uuid; v_m2 uuid;
  t1 uuid; t3 uuid; s text; n int; x uuid; v_base text; v_now text;
begin
  insert into organizations (name) values ('__TEST_techactive') returning id into v_org;
  insert into organizations (name) values ('__TEST_techactive_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_tp := pg_temp.mkuser('technician', v_org);
  v_m2 := pg_temp.mkuser('master', v_org2);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_tp, true) returning id into v_tech;

  perform pg_temp.chk('one definition, STABLE, SECURITY DEFINER with a fixed search_path',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'current_technician_id') = 1
    and (select provolatile = 's' and prosecdef and coalesce(proconfig::text like '%search_path=%', false) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'current_technician_id'));
  perform pg_temp.chk('no PUBLIC grant appears on it',
    not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and p.proname = 'current_technician_id' and a.grantee = 0));
  t1 := pg_temp.mk(v_org, v_tp, v_ops);
  perform pg_temp.as_user(v_tp);
  select public.current_technician_id() into x;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an active technician resolves to their technician id', x = v_tech, coalesce(x::text, 'null'));
  update technicians set is_active = false where id = v_tech;
  perform pg_temp.as_user(v_tp);
  select public.current_technician_id() into x;
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a deactivated technician: current_technician_id() is NULL and they can no longer read tasks', x is null and n = 0, coalesce(x::text, 'null') || '/' || n::text);
  t3 := t1;
  perform pg_temp.as_user(v_tp);
  update tasks set status = 'done' where id = t3;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a deactivated technician cannot finish a task assigned to them', (select status::text from tasks where id = t3) = 'open');
  update technicians set is_active = true where id = v_tech;


  perform pg_temp.as_user(v_m2);
  select count(*) into n from tasks where org_id = v_org;
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none of these tasks', n = 0, n::text);

  -- ---------- real data: relative to the baseline the wrapper took before the migration ----------
  begin
    v_base := current_setting('gv.baseline', true);
    v_now := pg_temp.gv_fingerprint();
    perform pg_temp.chk('the REAL organisations are unchanged by the migration and these tests (fingerprint equals the pre-migration baseline)',
      v_base is not null and v_base = v_now, coalesce(left(v_base, 40), 'no baseline') || ' / ' || coalesce(left(v_now, 40), '-'));
  exception when undefined_function then
    perform pg_temp.chk('real-data fingerprint skipped: this file was not run through the wrapper (no baseline)', true);
  end;

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
