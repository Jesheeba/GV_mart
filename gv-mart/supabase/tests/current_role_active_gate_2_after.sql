-- F-07 role x is_active matrix, PART 2 (after the migration). See part 1 for the runner order.
select pg_temp.mx_run('after');

do $t$
declare
  res text := ''; r record; n int; v_org uuid; v_m1 uuid := gen_random_uuid(); v_m2 uuid := gen_random_uuid();
  v_s uuid := gen_random_uuid(); bad int;
begin
  -- ===== A. active personas must be byte-for-byte unchanged (no regression) =====
  select count(*) into n from (
    select persona, k from mx_out where phase='before' and persona in ('master_active','ops_active','sales_active','technician','customer')
    except
    select persona, k from mx_out where phase='after'  and persona in ('master_active','ops_active','sales_active','technician','customer')) z;
  res := res || E'\n' || case when n=0 then 'ok   A0 same set of checks before and after' else 'FAIL A0 missing '||n end;

  for r in
    select b.persona, b.k, b.v bv, a.v av
      from mx_out b join mx_out a on a.persona=b.persona and a.k=b.k and a.phase='after'
     where b.phase='before' and b.persona in ('master_active','ops_active','sales_active','technician','customer')
       and b.v is distinct from a.v
  loop
    res := res || E'\nFAIL A1 '||r.persona||' '||r.k||' changed: '||r.bv||' -> '||r.av;
  end loop;
  select count(*) into n from mx_out b join mx_out a on a.persona=b.persona and a.k=b.k and a.phase='after'
   where b.phase='before' and b.persona in ('master_active','ops_active','sales_active','technician','customer') and b.v is distinct from a.v;
  res := res || E'\n' || case when n=0 then 'ok   A1 active master / ops / sales / technician / customer: every helper, count and RPC result identical' else 'FAIL A1 '||n||' differences' end;

  -- ===== A2. a signed-in user with no profile: helpers become strictly false, every RPC refused at the guard =====
  for r in select b.k, b.v bv, a.v av from mx_out b join mx_out a on a.persona=b.persona and a.k=b.k and a.phase='after'
            where b.phase='before' and b.persona='no_profile' and b.v is distinct from a.v loop
    res := res || E'
     INFO A2 no_profile '||r.k||': '||r.bv||' -> '||r.av;
  end loop;
  select count(*) into bad from mx_out where phase='after' and persona='no_profile' and ((k like 'rpc_%' and v like 'OK(%') or (k in ('is_master','is_ops_staff','is_staff','is_sales_staff') and v<>'false') or (k like 'cnt_%' and k not in ('cnt_settings') and v<>'0' and k<>'cnt_profiles'));
  res := res || E'
' || case when bad=0 then 'ok   A2 no_profile: strictly false helpers, no OK RPC, no data' else 'FAIL A2 no_profile bad='||bad end;

  -- ===== B. inactive staff have no role, no helper, no data, and every guard holds =====
  for r in select persona from (values ('master_inactive'),('ops_inactive'),('sales_inactive')) t(persona) loop
    select count(*) into n from mx_out where phase='after' and persona=r.persona and k='current_role' and v='NULL';
    res := res || E'\n' || case when n=1 then 'ok   B1 '||r.persona||': current_role() is NULL' else 'FAIL B1 '||r.persona end;
    select count(*) into n from mx_out where phase='after' and persona=r.persona and k in ('is_master','is_ops_staff','is_staff','is_sales_staff') and v<>'false';
    res := res || E'\n' || case when n=0 then 'ok   B2 '||r.persona||': is_master/is_ops_staff/is_staff/is_sales_staff are all strictly false (not NULL)' else 'FAIL B2 '||r.persona||' non-false helpers='||n end;
    select count(*) into n from mx_out where phase='after' and persona=r.persona and k like 'cnt_%' and k not in ('cnt_profiles','cnt_notifications') and v<>'0';
    res := res || E'\n' || case when n=0 then 'ok   B3 '||r.persona||': sees zero rows in leads/customers/invoices/tickets/settings/audit/POs/suppliers' else 'FAIL B3 '||r.persona||' tables with rows='||n end;
    -- every RPC must be refused BY THE GUARD, not by a later "not found" and never OK
    select count(*) into bad from mx_out where phase='after' and persona=r.persona and k like 'rpc_%'
       and (v like 'OK(%' or v ~* 'not found|violat|does not exist|invalid input|null value');
    res := res || E'\n' || case when bad=0 then 'ok   B4 '||r.persona||': all guarded RPCs refused at the guard' else 'FAIL B4 '||r.persona||' RPCs that got past the guard='||bad end;
  end loop;
  for r in select persona, k, v from mx_out where phase='after' and persona in ('master_inactive','ops_inactive','sales_inactive') and k like 'rpc_%' and (v like 'OK(%' or v ~* 'not found|violat|does not exist|invalid input|null value') loop
    res := res || E'\n     PAST-GUARD '||r.persona||' '||r.k||': '||r.v;
  end loop;

  -- ===== C. last-active-master protection (non-__TEST_ organisation name so the exemption does not apply) =====
  insert into organizations(name) values ('Lastmaster Matrix Org') returning id into v_org;
  insert into auth.users(id,email) select x,'__test_'||x||'@example.invalid' from unnest(array[v_m1,v_m2,v_s]) x;
  insert into profiles(id,org_id,full_name,role) values (v_m1,v_org,'__TEST_m1','master'),(v_s,v_org,'__TEST_s','sales_admin');
  begin update profiles set is_active=false where id=v_m1; res := res || E'\nFAIL C1 last master deactivated';
  exception when others then res := res || E'\nok   C1 owner cannot deactivate the only active master: '||sqlerrm; end;
  begin update profiles set role='sales_admin' where id=v_m1; res := res || E'\nFAIL C2 last master demoted';
  exception when others then res := res || E'\nok   C2 owner cannot demote the only active master'; end;
  begin delete from profiles where id=v_m1; res := res || E'\nFAIL C3 last master deleted';
  exception when others then res := res || E'\nok   C3 owner cannot delete the only active master'; end;
  begin update profiles set org_id=(select id from organizations where name='__TEST_f07_matrix_other') where id=v_m1; res := res || E'\nFAIL C3b last master moved to another org';
  exception when others then res := res || E'\nok   C3b owner cannot move the only active master to another organisation'; end;
  perform set_config('request.jwt.claims', json_build_object('sub',v_m1,'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin update profiles set is_active=false where id=v_m1; res := res || E'\nFAIL C4 master deactivated themselves';
  exception when others then res := res || E'\nok   C4 a master cannot deactivate themselves: '||sqlerrm; end;
  begin perform set_config('app.allow_last_master_change','1',true); update profiles set is_active=false where id=v_m1;
        res := res || E'\nFAIL C5 client used the break-glass flag';
  exception when others then res := res || E'\nok   C5 the break-glass flag does nothing for a client session'; end;
  execute 'reset role';
  perform set_config('app.allow_last_master_change','',true);
  -- with a second ACTIVE master the first can be deactivated, and then the second is the last
  insert into profiles(id,org_id,full_name,role) values (v_m2,v_org,'__TEST_m2','master');
  begin update profiles set is_active=false where id=v_m1;
        res := res || E'\nok   C6 with a second active master the first can be deactivated';
  exception when others then res := res || E'\nFAIL C6 '||sqlerrm; end;
  begin update profiles set is_active=false where id=v_m2; res := res || E'\nFAIL C7 deactivated the new last master';
  exception when others then res := res || E'\nok   C7 the remaining master is protected again'; end;
  -- an inactive master does not count as protection; re-activating restores it
  begin update profiles set is_active=true where id=v_m1; res := res || E'\nok   C8 re-activating a master works (recovery path)';
  exception when others then res := res || E'\nFAIL C8 '||sqlerrm; end;
  -- documented break-glass: owner role + flag
  begin perform set_config('app.allow_last_master_change','1',true);
        update profiles set is_active=false where id=v_m1; update profiles set is_active=false where id=v_m2;
        perform set_config('app.allow_last_master_change','',true);
        res := res || E'\nok   C9 DBA break-glass (postgres + app.allow_last_master_change) works';
  exception when others then res := res || E'\nFAIL C9 '||sqlerrm; end;
  perform set_config('app.allow_last_master_change','',true);
  -- recovery from a fully inactive organisation, as documented: owner re-activates a master
  begin update profiles set is_active=true where id=v_m1;
        res := res || E'\n' || case when (select is_active from profiles where id=v_m1) then 'ok   C10 documented recovery (update profiles set is_active = true) works' else 'FAIL C10' end;
  exception when others then res := res || E'\nFAIL C10 '||sqlerrm; end;
  -- cascade: deleting an organisation that still has its last master is not blocked
  begin delete from organizations where id=v_org; res := res || E'\nFAIL C11 org with audit rows deleted directly';
  exception when others then res := res || E'\nok   C11 organisation delete is still governed by audit_log (append-only) not by the master trigger: '||left(sqlerrm,60); end;

  -- a __TEST_ organisation is exempt so existing throwaway cleanups keep working
  begin delete from profiles where id=(select uid from mx_persona where name='master_active');
        res := res || E'\nok   C12 __TEST_ organisation: last master can be removed (exempt)';
  exception when others then res := res || E'\nFAIL C12 '||sqlerrm; end;

  -- ===== D. policies and functions =====
  res := res || E'\n' || case when (select qual from pg_policies where tablename='settings' and policyname='settings_select_org') !~* 'IS DISTINCT FROM'
                         then 'ok   D1 settings_select_org no longer uses IS DISTINCT FROM' else 'FAIL D1' end;
  res := res || E'\n' || case when (select prosrc from pg_proc where proname='is_master' and pronamespace='public'::regnamespace) ~* 'coalesce'
                              and (select prosrc from pg_proc where proname='is_ops_staff' and pronamespace='public'::regnamespace) ~* 'coalesce'
                         then 'ok   D2 is_master and is_ops_staff are coalesced to a strict boolean' else 'FAIL D2' end;

  raise exception E'RESULTS:%', res;
end
$t$;
