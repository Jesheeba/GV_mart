-- Rolled-back DB tests for Phase 2 gap 2 (migration 20261008100000_lead_stage_log). One transaction ending in RAISE; read RESULTS in the error.
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
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__T ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; txt text; b boolean;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; f jsonb; rec record; w_from timestamptz := '2000-01-01'; w_to timestamptz := '2100-01-01';
  old_total int; fp_before text; fp_after text; n int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  v_master := pg_temp.mkuser('master', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  select md5(string_agg(id::text||status||coalesce(lost_reason,''), ',' order by id)) into fp_before from leads where created_at < now() - interval '1 minute';

  -- backfill
  perform pg_temp.chk('backfill: every pre-existing lead has exactly 1 backfill row',
    (select count(*) from leads l where created_at < now() - interval '1 minute' and (select count(*) from lead_stage_log g where g.lead_id=l.id and g.source='backfill')=1)
    = (select count(*) from leads where created_at < now() - interval '1 minute'));
  perform pg_temp.chk('backfill rows: from_status null, changed_by null', not exists (select 1 from lead_stage_log where source='backfill' and (from_status is not null or changed_by is not null)));

  -- creation + transitions
  insert into leads(org_id,name,mobile) values (v_org,'__T_a','9444444401') returning id into l1;
  perform pg_temp.chk('new lead: 1 creation row new', (select count(*) from lead_stage_log where lead_id=l1 and source='creation' and from_status is null and to_status='new')=1);
  insert into leads(org_id,name,mobile,status) values (v_org,'__T_closed_ins','9444444402','lost') returning id into l2;
  perform pg_temp.chk('lead inserted already lost: creation row to=lost', (select count(*) from lead_stage_log where lead_id=l2 and to_status='lost' and source='creation')=1);

  -- stage buttons (client direct update by sales_admin is allowed by leads_update_sales) are logged with changed_by
  perform pg_temp.as_user(v_sales);
  update leads set status='contacted' where id=l1;
  update leads set status='quoted' where id=l1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('transitions logged with from/to + author', (select count(*) from lead_stage_log where lead_id=l1 and from_status='new' and to_status='contacted' and changed_by=v_sales)=1
    and (select count(*) from lead_stage_log where lead_id=l1 and from_status='contacted' and to_status='quoted' and changed_by=v_sales)=1);
  update leads set status='quoted' where id=l1;
  select count(*) into n from lead_stage_log where lead_id=l1;
  perform pg_temp.chk('no-op status update writes nothing', n=3, n::text);

  -- append-only, as every role
  for rec in select * from (values ('postgres',null::uuid),('master',v_master),('sales_admin',v_sales)) x(role, uid) loop
    if rec.uid is not null then perform pg_temp.as_user(rec.uid); end if;
    begin update lead_stage_log set reason='x' where lead_id=l1; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('log UPDATE rejected '||rec.role, b=false);
    begin delete from lead_stage_log where lead_id=l1; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('log DELETE rejected '||rec.role, b=false);
    if rec.uid is not null then
      begin insert into lead_stage_log(org_id,lead_id,to_status) values (v_org,l1,'won'); b:=true; exception when others then b:=false; end;
      perform pg_temp.chk('log direct INSERT rejected '||rec.role, b=false);
    end if;
    perform pg_temp.as_pg();
  end loop;

  -- read access: master only
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('master reads log', (select count(*) from lead_stage_log where lead_id=l1)>=3);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('sales_admin sees 0 log rows', (select count(*) from lead_stage_log)=0);
  perform pg_temp.as_pg();

  -- deleting a lead still works (cascade passes the append-only guard)
  delete from leads where id=l2;
  perform pg_temp.chk('lead delete cascades its log rows', (select count(*) from lead_stage_log where lead_id=l2)=0);

  -- funnel: lead with history lost at 'quoted'; lead lost via creation (unknown)
  update leads set status='lost', lost_reason='x' where id=l1;
  insert into leads(org_id,name,mobile,status) values (v_org,'__T_won','9444444403','won') returning id into l3;
  insert into leads(org_id,name,mobile,status) values (v_org,'__T_unk','9444444404','lost') returning id into l4;
  perform pg_temp.as_user(v_master);
  f := get_lead_funnel(w_from, w_to);
  perform pg_temp.as_pg();
  select count(*) into old_total from leads where org_id=v_org;
  perform pg_temp.chk('funnel total = lead count', (f->>'total')::int = old_total, f->>'total');
  perform pg_temp.chk('funnel by_status matches leads', (f->'by_status') = (select jsonb_build_object('new',count(*) filter (where status='new'),'contacted',count(*) filter (where status='contacted'),'quoted',count(*) filter (where status='quoted'),'won',count(*) filter (where status='won'),'lost',count(*) filter (where status='lost')) from leads where org_id=v_org));
  perform pg_temp.chk('lost with history is placed (known=1); creation-lost stays unknown',
    (f->>'lost_stage_known')::int = 1 and (f->>'lost_stage_unknown')::int = (select count(*) from leads where org_id=v_org and status='lost')-1,
    (f->>'lost_stage_known') || '/' || (f->>'lost_stage_unknown'));
  perform pg_temp.chk('funnel reached.contacted = (contacted+quoted+won status) + the lost-at-quoted lead',
    (f->'reached'->>'contacted')::int = (select count(*) from leads where org_id=v_org and status in ('contacted','quoted','won')) + 1);
  perform pg_temp.chk('funnel reached.won = won leads', (f->'reached'->>'won')::int = (select count(*) from leads where org_id=v_org and status='won'));
  -- parity with the old (current-status-only) formulas, ignoring the 2 test leads that differ by design
  perform pg_temp.chk('REAL DATA parity: reached.created == total - lost leads of unknown stage',
    (f->'reached'->>'created')::int = (select count(*) from leads where org_id=v_org) - (f->>'lost_stage_unknown')::int);

  -- anon rejected
  begin execute 'set local role anon'; perform get_lead_funnel(w_from, w_to); b:=true; exception when others then b:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('anon cannot call get_lead_funnel', b=false);
  begin perform pg_temp.as_user(v_sales); perform get_lead_funnel(w_from, w_to); b:=true; exception when others then b:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin may call get_lead_funnel (staff)', b);

  select md5(string_agg(id::text||status||coalesce(lost_reason,''), ',' order by id)) into fp_after from leads where created_at < now() - interval '1 minute';
  perform pg_temp.chk('real leads untouched by the test', fp_before = fp_after);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
