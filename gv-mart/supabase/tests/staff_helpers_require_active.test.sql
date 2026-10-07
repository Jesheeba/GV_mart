-- Rolled-back proof for the HELD migration supabase/held/20261010110000_staff_helpers_require_active.sql.
-- Applies the new helpers INSIDE the transaction only, compares them with the old definition
-- for every role x is_active combination, then checks real table access. Always ends in RAISE.
do $t$
declare
  res text := ''; v_org uuid; r record; old_s boolean; old_st boolean; new_s boolean; new_st boolean;
  ids jsonb := '{}'; v_id uuid; n int; i int;
  roles text[] := array['master','operation_admin','sales_admin','technician','customer'];
  v_role text; v_act boolean; v_l uuid;
begin
  insert into organizations(name) values ('__TEST_helper_org') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict do nothing;

  foreach v_role in array roles loop
    foreach v_act in array array[true,false] loop
      v_id := gen_random_uuid();
      insert into auth.users(id,email) values (v_id,'__test_'||v_id||'@example.invalid');
      insert into profiles(id,org_id,full_name,role,is_active) values (v_id,v_org,'__TEST_'||v_role||'_'||v_act,v_role::user_role,v_act);
      ids := ids || jsonb_build_object(v_role||'_'||v_act, v_id);
    end loop;
  end loop;

  -- capture OLD behaviour, then apply the new helpers inside this transaction
  create temp table _old(k text primary key, s boolean, st boolean) on commit drop;
  for r in select k, v::text::uuid id from jsonb_each_text(ids) e(k,v) loop
    perform set_config('request.jwt.claims', json_build_object('sub',r.id,'role','authenticated')::text, true);
    insert into _old values (r.k, public.is_sales_staff(), public.is_staff());
  end loop;

  execute $f$
    create or replace function public.is_sales_staff() returns boolean language sql stable security definer set search_path = public as $q$
      select exists (select 1 from public.profiles where id = auth.uid() and (role = 'master' or (role = 'sales_admin' and is_active))) $q$ $f$;
  execute $f$
    create or replace function public.is_staff() returns boolean language sql stable security definer set search_path = public as $q$
      select exists (select 1 from public.profiles where id = auth.uid() and (role in ('master','operation_admin') or (role = 'sales_admin' and is_active))) $q$ $f$;

  for r in select k, v::text::uuid id from jsonb_each_text(ids) e(k,v) order by 1 loop
    perform set_config('request.jwt.claims', json_build_object('sub',r.id,'role','authenticated')::text, true);
    new_s := public.is_sales_staff(); new_st := public.is_staff();
    select s, st into old_s, old_st from _old where k=r.k;
    if r.k like 'sales_admin_false' then
      res := res || E'\n' || case when old_s and old_st and not new_s and not new_st then 'ok   inactive sales_admin: was staff, now NOT (is_sales_staff '||old_s||'->'||new_s||', is_staff '||old_st||'->'||new_st||')' else 'FAIL inactive sales_admin' end;
    else
      res := res || E'\n' || case when old_s=new_s and old_st=new_st then 'ok   unchanged '||rpad(r.k,26)||' is_sales_staff='||new_s||' is_staff='||new_st else 'FAIL CHANGED '||r.k end;
    end if;
  end loop;
  -- no session at all
  perform set_config('request.jwt.claims','',true);
  res := res || E'\n' || case when not public.is_sales_staff() and not public.is_staff() then 'ok   no session: both false' else 'FAIL no session' end;

  -- real table access as each persona (leads: sales policies + staff select)
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_visible','9200000001') returning id into v_l;
  foreach v_role in array array['master','operation_admin','sales_admin'] loop
    foreach v_act in array array[true,false] loop
      perform set_config('request.jwt.claims', json_build_object('sub',(ids->>(v_role||'_'||v_act))::uuid,'role','authenticated')::text, true);
      execute 'set local role authenticated';
      select count(*) into n from leads where id=v_l;
      begin insert into leads(org_id,name,mobile) values (v_org,'__TEST_w_'||v_role||v_act,'9200000009'); i:=1; exception when others then i:=0; end;
      execute 'reset role';
      res := res || E'\n' || format('info %-16s active=%-5s  can SELECT lead:%s  can INSERT lead:%s', v_role, v_act, n, i);
    end loop;
  end loop;
  raise exception E'RESULTS:%', res;
end
$t$;
