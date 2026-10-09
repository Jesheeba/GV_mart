-- Rolled-back DB tests for migration 20261012110000_customer_member_email (batch-17 item 6).
-- One transaction ending in RAISE; read RESULTS in the error. Uses a throwaway __TEST_ organisation created
-- inside the transaction, so nothing persists and no real customer row is read or written.
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
  v_org uuid; v_master uuid; txt text; b boolean; n int; c1 uuid; c2 uuid; c3 uuid; c4 uuid; r record;
  addr jsonb := '{"area":"__TEST_ area","address_type":"residential","ownership":"own"}';
begin
  insert into organizations (name) values ('__TEST_b17_email') returning id into v_org;
  v_master := pg_temp.mkuser('master', v_org);

  perform pg_temp.chk('customer_members.email column exists and is nullable', (select is_nullable from information_schema.columns where table_schema='public' and table_name='customer_members' and column_name='email')='YES');
  perform pg_temp.chk('exactly one create_customer_with_details overload', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='create_customer_with_details')=1);
  perform pg_temp.chk('authenticated can still execute the RPC', has_function_privilege('authenticated','public.create_customer_with_details(uuid,text,text,jsonb,jsonb)','execute'));

  perform pg_temp.as_user(v_master);

  -- new-style payload: profession + email per member, no customer-level profession
  c1 := create_customer_with_details(v_org, '', 'other',
    '[{"name":"__TEST_ Primary","mobile":"9000000201","is_primary":true,"profession":"Teacher","email":"primary@test.invalid"},
      {"name":"__TEST_ Spouse","mobile":"9000000202","is_primary":false,"relation":"spouse","profession":"Doctor","email":"spouse@test.invalid"},
      {"name":"__TEST_ Son","mobile":"9000000203","is_primary":false,"relation":"son"}]'::jsonb, addr);
  perform pg_temp.as_pg();
  perform pg_temp.chk('members get profession and email', (select count(*) from customer_members where customer_id=c1 and email is not null and profession is not null)=2);
  perform pg_temp.chk('a member without email/profession stores NULL (not empty string)', (select email is null and profession is null from customer_members where customer_id=c1 and name='__TEST_ Son'));
  perform pg_temp.chk('customer profession falls back to the primary member profession', (select profession from customers where id=c1)='Teacher');
  perform pg_temp.chk('exactly one primary member', (select count(*) from customer_members where customer_id=c1 and is_primary)=1);

  -- an explicit customer-level profession still wins
  perform pg_temp.as_user(v_master);
  c2 := create_customer_with_details(v_org, 'Engineer', 'other', '[{"name":"__TEST_ Solo","mobile":"9000000204","is_primary":true,"profession":"Teacher"}]'::jsonb, addr);
  perform pg_temp.as_pg();
  perform pg_temp.chk('explicit p_profession still wins over the member profession', (select profession from customers where id=c2)='Engineer');

  -- old-style payload (no profession/email keys at all) and empty profession keep old behaviour
  perform pg_temp.as_user(v_master);
  c3 := create_customer_with_details(v_org, '', 'other', '[{"name":"__TEST_ Old","mobile":"9000000205","is_primary":true}]'::jsonb, addr);
  perform pg_temp.as_pg();
  perform pg_temp.chk('old-style payload still works; empty profession stays empty', (select profession from customers where id=c3) = '' and (select email is null from customer_members where customer_id=c3));

  -- blank strings become NULL
  perform pg_temp.as_user(v_master);
  c4 := create_customer_with_details(v_org, '', 'other', '[{"name":"__TEST_ Blank","mobile":"9000000206","is_primary":true,"profession":"  ","email":"  "}]'::jsonb, addr);
  perform pg_temp.as_pg();
  perform pg_temp.chk('blank profession/email strings are stored as NULL', (select email is null and profession is null from customer_members where customer_id=c4));

  -- format check
  begin update customer_members set email='not-an-email' where customer_id=c1 and is_primary; b:=true; exception when check_violation then b:=false; end;
  perform pg_temp.chk('malformed email rejected by the check constraint', b=false);
  begin update customer_members set email='a b@c.d' where customer_id=c1 and is_primary; b:=true; exception when check_violation then b:=false; end;
  perform pg_temp.chk('email with a space rejected', b=false);
  begin update customer_members set email='someone@example.co.in' where customer_id=c1 and is_primary; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('normal email accepted', b);
  begin update customer_members set email=null where customer_id=c1 and is_primary; b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('email can be cleared back to NULL', b);

  -- member limit trigger still enforced through the RPC
  perform pg_temp.as_user(v_master);
  begin
    perform create_customer_with_details(v_org, '', 'other', (select jsonb_agg(jsonb_build_object('name','__TEST_ m'||g,'mobile','90000003'||lpad(g::text,2,'0'),'is_primary',g=1,'email','m'||g||'@test.invalid')) from generate_series(1,6) g), addr);
    b := true;
  exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('more than 5 members still rejected', b=false);

  -- direct writes by staff (the add/edit member forms) accept email
  perform pg_temp.as_user(v_master);
  insert into customer_members (org_id, customer_id, name, mobile, is_primary, email, profession) values (v_org, c2, '__TEST_ Added', '9000000207', false, 'added@test.invalid', 'Clerk');
  update customer_members set email='edited@test.invalid' where customer_id=c2 and name='__TEST_ Added';
  perform pg_temp.as_pg();
  perform pg_temp.chk('staff can add and edit a member email directly', (select email from customer_members where customer_id=c2 and name='__TEST_ Added')='edited@test.invalid');

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
