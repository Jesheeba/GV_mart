-- Rolled-back DB tests for Phase 2 gap 1 (migration 20261008110000_lead_reopen_with_reason). One transaction ending in RAISE; read RESULTS in the error.
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
create function pg_temp.ro(p_lead uuid, p_due timestamptz, p_reason text, p_type public.lead_followup_type default 'call', p_note text default null) returns jsonb language sql as $f$ select public.reopen_lead(p_lead, p_due, p_reason, p_type, p_note, false) $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;


do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; v_ops uuid; v_tech uuid; v_cust uuid; txt text; b boolean; n int; r jsonb;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; rec record; fp_before text; fp_after text;
  o_notint uuid; o_won uuid; o_asked uuid; due timestamptz := now() + interval '2 days';
  fcount_before int;
begin
  select org_id into v_org from profiles where role='master' limit 1;
  v_master := pg_temp.mkuser('master', v_org); v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_ops := pg_temp.mkuser('operation_admin', v_org); v_tech := pg_temp.mkuser('technician', v_org); v_cust := pg_temp.mkuser('customer', v_org);
  select id into o_notint from lead_outcomes where org_id=v_org and code='not_interested';
  select id into o_won from lead_outcomes where org_id=v_org and code='bought_from_us';
  select id into o_asked from lead_outcomes where org_id=v_org and code='asked_price';
  select md5(string_agg(id::text||status||coalesce(lost_reason,''), ',' order by id)) into fp_before from leads where created_at < now() - interval '1 minute';

  -- ===== source tagging =====
  insert into leads(org_id,name,mobile) values (v_org,'__T_r1','9555555501') returning id into l1;
  perform pg_temp.as_user(v_sales);
  perform update_lead_status(l1, 'contacted');
  perform update_lead_status(l1, 'quoted');
  perform pg_temp.as_pg();
  perform pg_temp.chk('stage buttons logged as source stage_button', (select count(*) from lead_stage_log where lead_id=l1 and source='stage_button')=2);
  perform pg_temp.as_user(v_sales);
  perform log_lead_outcome(l1, o_notint, 'not keen', 'call', null);   -- closes as lost from 'quoted'
  perform pg_temp.as_pg();
  perform pg_temp.chk('log_lead_outcome close logged as source outcome, from quoted', (select count(*) from lead_stage_log where lead_id=l1 and source='outcome' and from_status='quoted' and to_status='lost')=1);
  update leads set status = 'quoted' where id = l1 and false;
  perform pg_temp.chk('lead is lost', (select status from leads where id=l1)='lost');

  -- ===== update_lead_status: closed leads are frozen =====
  perform pg_temp.as_user(v_sales);
  begin perform update_lead_status(l1, 'won'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('lost -> won via stage RPC blocked', b=false);
  begin perform update_lead_status(l1, 'lost', 'again'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('lost -> lost (reason rewrite) via stage RPC blocked', b=false);
  begin perform update_lead_status(l1, 'new'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('lost -> new via stage RPC blocked', b=false);
  perform pg_temp.as_pg();

  -- ===== new reopen: validation and permissions =====
  for rec in select * from (values ('operation_admin',v_ops),('technician',v_tech),('customer',v_cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin perform pg_temp.ro(l1, due, 'customer called back'); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('reopen_lead (new) rejected for '||rec.role, b=false);
    begin perform pg_temp.ro(l1, due, 'ok'::text, 'call'); b:=true; exception when others then b:=false; end;
    perform pg_temp.as_pg();
  end loop;
  begin execute 'set local role anon'; perform reopen_lead(l1, due, 'customer called back'); b:=true; exception when others then b:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('reopen_lead (new) rejected for anon', b=false);
  perform pg_temp.as_user(v_sales);
  begin perform pg_temp.ro(l1, due, 'ab'); b:=true; exception when others then b:=sqlerrm not like '%reason%'; end;
  perform pg_temp.chk('2-char reason rejected', b=false);
  begin perform pg_temp.ro(l1, due, '   '); b:=true; exception when others then b:=sqlerrm not like '%reason%'; end;
  perform pg_temp.chk('blank reason rejected', b=false);
  begin perform pg_temp.ro(l1, due, null); b:=true; exception when others then b:=sqlerrm not like '%reason%'; end;
  perform pg_temp.chk('null reason rejected', b=false);
  begin perform pg_temp.ro(l1, now() - interval '3 days', 'valid reason'); b:=true; exception when others then b:=sqlerrm not like '%past%'; end;
  perform pg_temp.chk('past follow-up date still rejected', b=false);
  perform pg_temp.chk('rejections left the lead lost', (select status from leads where id=l1)='lost' and (select count(*) from lead_followups where lead_id=l1 and status='open')=0);

  -- ===== new reopen: returns to pre-closing stage =====
  r := pg_temp.ro(l1, due, '  customer called back  ', 'call', 'asked again');
  perform pg_temp.as_pg();
  perform pg_temp.chk('reopen returns to quoted (pre-closing stage), stage known', r->>'status'='quoted' and (r->>'stage_was_known')::boolean, r::text);
  perform pg_temp.chk('lead open, lost_reason cleared, postpone 0, 1 open follow-up (source reopen)',
    (select status='quoted' and lost_reason is null and postpone_count=0 from leads where id=l1)
    and (select count(*) from lead_followups where lead_id=l1 and status='open' and source='reopen')=1);
  perform pg_temp.chk('stage log: reopen row has trimmed reason, source reopen, from lost to quoted',
    (select count(*) from lead_stage_log where lead_id=l1 and source='reopen' and from_status='lost' and to_status='quoted' and reason='customer called back' and changed_by=v_sales)=1);
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('timeline shows reopen reason on the stage_change event',
    exists (select 1 from lead_timeline(l1) t where t.kind='stage_change' and t.detail->>'from_status'='lost' and t.detail->>'note'='customer called back'));
  perform pg_temp.as_pg();

  -- closed twice: second close from 'contacted' -> reopen returns to contacted (latest close wins)
  perform pg_temp.as_user(v_sales);
  perform update_lead_status(l1, 'contacted');
  perform log_lead_outcome(l1, o_won, null, 'call', null);
  r := pg_temp.ro(l1, due, 'refund, selling again');
  perform pg_temp.as_pg();
  perform pg_temp.chk('won lead reopens to the stage it was in before THIS close (contacted)', r->>'status'='contacted', r::text);

  -- ===== unknown history falls back to contacted =====
  insert into leads(org_id,name,mobile,status) values (v_org,'__T_r2','9555555502','lost') returning id into l2;
  perform pg_temp.as_user(v_sales);
  r := pg_temp.ro(l2, due, 'found number again');
  perform pg_temp.as_pg();
  perform pg_temp.chk('unknown pre-close stage falls back to contacted, stage_was_known=false', r->>'status'='contacted' and not (r->>'stage_was_known')::boolean, r::text);

  -- reopen of an OPEN lead rejected
  perform pg_temp.as_user(v_sales);
  begin perform pg_temp.ro(l2, due, 'not closed'); b:=true; exception when others then b:=false; end;
  perform pg_temp.chk('reopen of an open lead rejected', b=false);
  perform pg_temp.as_pg();

  -- ===== backward compat: old 5-arg reopen_lead still works (deployed frontend) =====
  insert into leads(org_id,name,mobile) values (v_org,'__T_r3','9555555503') returning id into l3;
  perform pg_temp.as_user(v_sales);
  perform update_lead_status(l3, 'quoted');
  perform update_lead_status(l3, 'lost', 'no_longer_needs');
  r := reopen_lead(l3, due, 'call'::lead_followup_type, 'old frontend', false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('OLD 5-arg reopen_lead still works: contacted, 1 open follow-up', r->>'status'='contacted' and (select count(*) from lead_followups where lead_id=l3 and status='open')=1, r::text);
  perform pg_temp.chk('old reopen logged as source reopen with no reason', (select count(*) from lead_stage_log where lead_id=l3 and source='reopen' and reason is null)=1);

  -- ===== one-shot context: a later direct update does not inherit it =====
  update leads set status='quoted' where id=l3;
  perform pg_temp.chk('later direct update logged as source other', (select source from lead_stage_log where lead_id=l3 order by changed_at desc, id desc limit 1)='other');

  -- ===== won lead via create_sale-style direct update still logs; closed->won direct (sale) is not blocked =====
  update leads set status='lost', lost_reason='x' where id=l3;
  update leads set status='won' where id=l3;
  perform pg_temp.chk('direct lost->won (create_sale path) still works and is logged', (select status from leads where id=l3)='won' and (select count(*) from lead_stage_log where lead_id=l3 and from_status='lost' and to_status='won')=1);

  select md5(string_agg(id::text||status||coalesce(lost_reason,''), ',' order by id)) into fp_after from leads where created_at < now() - interval '1 minute';
  perform pg_temp.chk('real leads untouched by the test', fp_before = fp_after);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
