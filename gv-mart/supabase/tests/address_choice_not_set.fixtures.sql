-- Pre-migration fixtures for address_choice_not_set.test.sql (rolled-back rehearsal only). Throwaway __TEST_ org.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create temp table fx (k text primary key, v uuid);
grant all on fx to public;
create temp table real_before as
  select a.id, a.address_type, a.ownership from public.addresses a
  where a.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\');
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.fx(p_k text) returns uuid language sql as $f$ select v from pg_temp.fx where k = p_k $f$;
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
-- This project revokes default EXECUTE on new functions, so the helpers are granted explicitly.
grant execute on function pg_temp.chk(text, boolean, text), pg_temp.fx(text), pg_temp.mkuser(text, uuid), pg_temp.as_user(uuid), pg_temp.as_pg() to public;

do $fx$
declare v_org uuid; v uuid;
begin
  insert into organizations (name) values ('__TEST_addr_choice_org') returning id into v_org;
  insert into pg_temp.fx values ('org', v_org);
  insert into pg_temp.fx values ('master', pg_temp.mkuser('master', v_org));
  insert into pg_temp.fx values ('sales', pg_temp.mkuser('sales_admin', v_org));
  -- a pre-existing address keeps its stored answer through the migration
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ ac old', '9000000501') returning id into v;
  insert into pg_temp.fx values ('c_old', v);
  insert into addresses (org_id, customer_id, full_address, is_primary, address_type, ownership)
    values (v_org, v, '__TEST_ old addr', true, 'commercial', 'rental') returning id into v;
  insert into pg_temp.fx values ('a_old', v);
end $fx$;
