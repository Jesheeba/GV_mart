-- Rolled-back DB tests for the lead follow-up system (migrations 20261006200000 / 20261006210000).
-- Run through the Management API (database/query). Everything happens in one
-- transaction that ends in a RAISE, so nothing persists; read RESULTS in the error.
-- Roles are impersonated by setting request.jwt.claims + SET LOCAL ROLE authenticated,
-- using the existing master / sales_admin / operation_admin / technician / customer profiles.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;

do $t$
declare
  v_org uuid; v_master uuid; v_sales uuid; v_ops uuid; v_tech uuid; v_cust uuid;
  o_asked uuid; o_later uuid; o_interested uuid; o_won uuid; o_wrong uuid; o_notint uuid; o_notreach uuid;
  l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid;
  n int; n2 int; r jsonb; fa uuid; fb uuid; fc uuid; fd uuid; v_today date; txt text; b boolean;
  cnt_before int; rec record; v_custlead uuid; v_custid uuid;
begin
  select org_id, id into v_org, v_master from profiles where role='master' limit 1;
  select id into v_sales from profiles where role='sales_admin' limit 1;
  select id into v_ops from profiles where role='operation_admin' limit 1;
  select t.profile_id into v_tech from technicians t limit 1;
  select c.primary_profile_id, c.id into v_cust, v_custid from customers c where primary_profile_id is not null limit 1;
  select id into o_asked from lead_outcomes where org_id=v_org and code='asked_price';
  select id into o_later from lead_outcomes where org_id=v_org and code='will_buy_later';
  select id into o_interested from lead_outcomes where org_id=v_org and code='interested_send_details';
  select id into o_won from lead_outcomes where org_id=v_org and code='bought_from_us';
  select id into o_wrong from lead_outcomes where org_id=v_org and code='wrong_number';
  select id into o_notint from lead_outcomes where org_id=v_org and code='not_interested';
  select id into o_notreach from lead_outcomes where org_id=v_org and code='not_reachable';
  v_today := _lead_ist_date(now());
  perform pg_temp.chk('seed: 11 outcomes, 4 postpone-type', (select count(*) from lead_outcomes where org_id=v_org)=11 and (select count(*) from lead_outcomes where org_id=v_org and counts_as_postpone)=4);

  -- ===== 1. one open follow-up per lead + initial call =====
  insert into leads(org_id,name,mobile) values (v_org,'__T_one','9111111101') returning id into l1;
  select count(*) into n from lead_followups where lead_id=l1 and status='open';
  perform pg_temp.chk('new lead gets exactly 1 open Initial call', n=1);
  select * into rec from lead_followups where lead_id=l1;
  perform pg_temp.chk('initial call: source=initial_call, type=call, due in future', rec.source='initial_call' and rec.type='call' and rec.due_at>now(), rec.due_at::text);
  begin
    insert into lead_followups(org_id,lead_id,due_at) values (v_org,l1,now()+interval '1 day'); perform pg_temp.chk('second open follow-up rejected', false);
  exception when unique_violation then perform pg_temp.chk('second open follow-up rejected (unique index)', true); end;
  perform pg_temp.chk('leads.next_followup_at mirrors open task', (select next_followup_at from leads where id=l1) = rec.due_at);
  insert into leads(org_id,name,mobile,status) values (v_org,'__T_won_ins','9111111102','won') returning id into l2;
  perform pg_temp.chk('lead inserted already won gets no follow-up', (select count(*) from lead_followups where lead_id=l2)=0);

  -- ===== 2. log_lead_outcome: atomic + author + early contact =====
  perform pg_temp.as_user(v_sales);
  fa := (select id from lead_followups where lead_id=l1 and status='open');
  select count(*) into cnt_before from lead_activities where lead_id=l1;
  begin
    perform log_lead_outcome(l1, o_asked, 'x', 'call', null);
    perform pg_temp.chk('outcome without next date rejected', false);
  exception when others then perform pg_temp.chk('outcome without next date rejected', sqlerrm like '%follow-up date%', sqlerrm); end;
  perform pg_temp.chk('failed log_lead_outcome left nothing behind', (select count(*) from lead_activities where lead_id=l1)=cnt_before and (select status from lead_followups where id=fa)='open');
  begin
    perform log_lead_outcome(l1, o_asked, 'x', 'call', now() - interval '2 hours');
    perform pg_temp.chk('past follow-up rejected', false);
  exception when others then perform pg_temp.chk('past follow-up rejected', sqlerrm like '%in the past%', sqlerrm); end;
  r := log_lead_outcome(l1, o_asked, 'wants a quote', 'call', now() + interval '1 day', 'send_quote', 'send quote', false);
  fb := (r->>'followup_id')::uuid;
  perform pg_temp.chk('log_lead_outcome returned new followup + activity', fb is not null and (r->>'activity_id') is not null);
  select * into rec from lead_followups where id=fa;
  perform pg_temp.chk('early contact closes old task as done by the caller', rec.status='done' and rec.completed_by=v_sales and rec.completed_at < rec.due_at and rec.completing_activity_id=(r->>'activity_id')::uuid);
  perform pg_temp.chk('exactly one open task after outcome', (select count(*) from lead_followups where lead_id=l1 and status='open')=1 and (select id from lead_followups where lead_id=l1 and status='open')=fb);
  select * into rec from lead_activities where id=(r->>'activity_id')::uuid;
  perform pg_temp.chk('activity records author + outcome + note + channel', rec.created_by=v_sales and rec.outcome_id=o_asked and rec.note='wants a quote' and rec.type='call' and rec.is_system=false);
  perform pg_temp.chk('stage effect applied (new -> contacted)', (select status from leads where id=l1)='contacted');
  perform pg_temp.chk('stage change recorded with author + from/to', exists(select 1 from lead_activities where lead_id=l1 and type='status_change' and created_by=v_sales and from_status='new' and to_status='contacted'));
  perform pg_temp.chk('progress outcome keeps postpone_count 0', (select postpone_count from leads where id=l1)=0);
  perform pg_temp.chk('followup author = caller', (select created_by from lead_followups where id=fb)=v_sales);

  -- ===== 3. reschedule history + postpone/stuck =====
  r := reschedule_followup(l1, now() + interval '2 days', 'customer travelling');
  fc := (r->>'followup_id')::uuid;
  r := reschedule_followup(l1, now() + interval '3 days', 'still busy');
  fd := (r->>'followup_id')::uuid;
  perform pg_temp.as_pg();
  select count(*) into n from lead_followups where lead_id=l1;
  perform pg_temp.chk('reschedule x2 keeps all rows: A done, B cancelled, C cancelled, D open (4 rows)', n=4);
  select * into rec from lead_followups where id=fb;
  perform pg_temp.chk('old task cancelled (not edited/deleted) with reason + author', rec.status='cancelled' and rec.cancel_reason='rescheduled' and rec.reschedule_reason='customer travelling' and rec.cancelled_by=v_sales and rec.due_at is not null);
  perform pg_temp.chk('new row links to the one it replaced', (select replaces_followup_id from lead_followups where id=fc)=fb and (select replaces_followup_id from lead_followups where id=fd)=fc);
  perform pg_temp.chk('2 later-reschedules => postpone_count 2', (select postpone_count from leads where id=l1)=2);
  perform pg_temp.as_user(v_sales);
  r := reschedule_followup(l1, now() + interval '1 hour', 'pull-in');
  perform pg_temp.chk('pulling a task EARLIER does not count as postpone', (select postpone_count from leads where id=l1)=2);
  r := log_lead_outcome(l1, o_later, 'later', 'call', now() + interval '30 days');
  perform pg_temp.chk('postpone-type outcome adds 1 (=3)', (r->>'postpone_count')::int=3);
  select count(*) into n from list_followups('all') where lead_id=l1 and is_stuck;
  perform pg_temp.chk('postpone_count 3 => stuck flag in My Day list', n=1);
  select count(*) into n from list_followups('all', null, null, null, true) where lead_id=l1;
  perform pg_temp.chk('"stuck only" filter finds it', n=1);
  r := log_lead_outcome(l1, o_notreach, null, 'call', now() + interval '1 day');
  perform pg_temp.chk('not-reachable is postpone-type (=4)', (r->>'postpone_count')::int=4);
  r := log_lead_outcome(l1, o_interested, 'ok', 'whatsapp', now() + interval '1 day');
  perform pg_temp.chk('progress outcome resets postpone_count to 0', (r->>'postpone_count')::int=0);
  select count(*) into n from list_followups('all', null, null, null, true) where lead_id=l1;
  perform pg_temp.chk('no longer stuck after progress', n=0);

  -- ===== 4. plain notes =====
  select count(*) into n from lead_followups where lead_id=l1;
  select postpone_count, next_followup_at into rec from leads where id=l1;
  perform add_lead_note(l1, 'customer sent a photo');
  perform pg_temp.chk('note on OPEN lead: no follow-up / postpone change', (select count(*) from lead_followups where lead_id=l1)=n and (select postpone_count from leads where id=l1)=rec.postpone_count and (select next_followup_at from leads where id=l1)=rec.next_followup_at);
  perform pg_temp.chk('note records author', exists(select 1 from lead_activities where lead_id=l1 and type='note' and note='customer sent a photo' and created_by=v_sales));
  begin perform add_lead_note(l1, '   '); perform pg_temp.chk('blank note rejected', false); exception when others then perform pg_temp.chk('blank note rejected', true); end;

  -- ===== 5. Won / Lost cancel or complete the task; reopen needs a task =====
  perform pg_temp.as_pg();
  insert into leads(org_id,name,mobile) values (v_org,'__T_won','9111111103') returning id into l3;
  insert into leads(org_id,name,mobile) values (v_org,'__T_lost','9111111104') returning id into l4;
  insert into leads(org_id,name,mobile) values (v_org,'__T_btn','9111111105') returning id into l5;
  perform pg_temp.as_user(v_sales);
  r := log_lead_outcome(l3, o_won, 'bought!');
  perform pg_temp.chk('Won via outcome: lead won, task done, no new task', (select status from leads where id=l3)='won' and (select count(*) from lead_followups where lead_id=l3 and status='open')=0 and (select status from lead_followups where lead_id=l3 order by created_at limit 1)='done');
  perform pg_temp.chk('Won via outcome: customer auto-linked', (select customer_id from leads where id=l3) is not null);
  r := log_lead_outcome(l4, o_notint, null);
  perform pg_temp.chk('Lost via outcome uses hint reason, closes lead, no open task', (select status from leads where id=l4)='lost' and (select lost_reason from leads where id=l4)='no_longer_needs' and (select count(*) from lead_followups where lead_id=l4 and status='open')=0);
  begin perform log_lead_outcome(l4, o_asked, null, 'call', now()+interval '1 day'); perform pg_temp.chk('outcome on closed lead rejected', false); exception when others then perform pg_temp.chk('outcome on closed lead rejected', sqlerrm like '%already lost%', sqlerrm); end;
  perform update_lead_status(l5, 'lost', 'price_too_high');
  perform pg_temp.chk('Lost via stage button CANCELS open task (reason lead_lost)', (select status from lead_followups where lead_id=l5 order by created_at limit 1)='cancelled' and (select cancel_reason from lead_followups where lead_id=l5 order by created_at limit 1)='lead_lost');
  begin perform update_lead_status(l5, 'contacted'); perform pg_temp.chk('stage button cannot reopen a closed lead', false); exception when others then perform pg_temp.chk('stage button cannot reopen a closed lead', sqlerrm like '%reopen_lead%', sqlerrm); end;
  begin perform update_lead_status(l3, 'lost', '  '); perform pg_temp.chk('Lost needs reason', false); exception when others then perform pg_temp.chk('Lost needs reason', sqlerrm like '%reason is required%'); end;
  begin update leads set status='contacted' where id=l5; perform pg_temp.chk('direct UPDATE reopen without follow-up rejected', false); exception when others then perform pg_temp.chk('direct UPDATE reopen without follow-up rejected', sqlerrm like '%requires a new follow-up%', sqlerrm); end;
  begin perform reopen_lead(l5, now() - interval '1 day'); perform pg_temp.chk('reopen with past date rejected', false); exception when others then perform pg_temp.chk('reopen with past date rejected', true); end;
  r := reopen_lead(l5, now() + interval '1 day', 'call', 'came back');
  perform pg_temp.chk('reopen_lead: contacted, lost_reason cleared, new open task', (select status from leads where id=l5)='contacted' and (select lost_reason from leads where id=l5) is null and (select count(*) from lead_followups where lead_id=l5 and status='open')=1 and (select source from lead_followups where lead_id=l5 and status='open')='reopen');
  perform pg_temp.chk('lost + reopen stage changes both recorded with author', (select count(*) from lead_activities where lead_id=l5 and type='status_change' and created_by=v_sales)=2);
  perform add_lead_note(l4, 'note on closed lead');
  perform pg_temp.chk('note on CLOSED lead allowed', exists(select 1 from lead_activities where lead_id=l4 and type='note'));
  perform pg_temp.as_pg();
  insert into leads(org_id,name,mobile) values (v_org,'__T_sale','9111111106') returning id into l6;
  update leads set status='won' where id=l6;
  perform pg_temp.chk('sale-style direct Won cancels open task (lead_won)', (select cancel_reason from lead_followups where lead_id=l6 limit 1)='lead_won');
  perform pg_temp.chk('sale-style Won still writes a stage-change history row', exists(select 1 from lead_activities where lead_id=l6 and type='status_change' and to_status='won'));

  -- ===== 6. IST boundaries =====
  perform pg_temp.chk('_lead_ist_date(2026-10-06 19:00Z = 00:30 IST Oct 7) = Oct 7', _lead_ist_date('2026-10-06 19:00:00+00')='2026-10-07');
  perform pg_temp.chk('_lead_ist_date(2026-10-06 18:29:59Z = 23:59:59 IST Oct 6) = Oct 6', _lead_ist_date('2026-10-06 18:29:59+00')='2026-10-06');
  insert into leads(org_id,name,mobile) values (v_org,'__T_b_today0030','9222222201') returning id into l1;
  insert into leads(org_id,name,mobile) values (v_org,'__T_b_yday2359','9222222202') returning id into l2;
  insert into leads(org_id,name,mobile) values (v_org,'__T_b_tom0030','9222222203') returning id into l3;
  insert into leads(org_id,name,mobile) values (v_org,'__T_b_plus8','9222222204') returning id into l4;
  update lead_followups set due_at=_lead_ist_ts(v_today,'00:30') where lead_id=l1 and status='open';
  update lead_followups set due_at=_lead_ist_ts(v_today-1,'23:59') where lead_id=l2 and status='open';
  update lead_followups set due_at=_lead_ist_ts(v_today+1,'00:30') where lead_id=l3 and status='open';
  update lead_followups set due_at=_lead_ist_ts(v_today+8,'10:00') where lead_id=l4 and status='open';
  perform pg_temp.as_user(v_sales);
  perform pg_temp.chk('00:30 IST today (=prev UTC day) is in TODAY', (select bucket from list_followups('all') where lead_id=l1)='today');
  perform pg_temp.chk('23:59 IST yesterday is OVERDUE', (select bucket from list_followups('all') where lead_id=l2)='overdue');
  perform pg_temp.chk('00:30 IST tomorrow is UPCOMING', (select bucket from list_followups('all') where lead_id=l3)='upcoming');
  perform pg_temp.chk('+8 days is not in the next-7-days list', (select count(*) from list_followups('upcoming') where lead_id=l4)=0 and (select bucket from list_followups('all') where lead_id=l4)='later');
  perform pg_temp.chk('followup_counts counts today+overdue (>=2)', (followup_counts()->>'total')::int >= 2 and (select count(*) from list_followups('today') where lead_id=l1)=1);
  perform pg_temp.as_pg();

  -- ===== 7. working-day logic (Mon-Sat, 9:30-19:00 IST) =====
  perform pg_temp.chk('next working day after Saturday 2026-10-10 is Monday 2026-10-12', lead_next_working_day(v_org,'2026-10-10')='2026-10-12');
  perform pg_temp.chk('next working day after Friday is Saturday', lead_next_working_day(v_org,'2026-10-09')='2026-10-10');
  perform pg_temp.chk('initial due: Mon 10:00 IST -> Mon 11:00 IST', _lead_initial_due_at(v_org, _lead_ist_ts('2026-10-12','10:00'))=_lead_ist_ts('2026-10-12','11:00'));
  perform pg_temp.chk('initial due: Mon 08:00 IST (before open) -> Mon 10:00', _lead_initial_due_at(v_org, _lead_ist_ts('2026-10-12','08:00'))=_lead_ist_ts('2026-10-12','10:00'));
  perform pg_temp.chk('initial due: Sat 18:30 IST -> Mon 10:00', _lead_initial_due_at(v_org, _lead_ist_ts('2026-10-10','18:30'))=_lead_ist_ts('2026-10-12','10:00'));
  perform pg_temp.chk('initial due: Sunday 11:00 IST -> Mon 10:00', _lead_initial_due_at(v_org, _lead_ist_ts('2026-10-11','11:00'))=_lead_ist_ts('2026-10-12','10:00'));

  -- ===== 8. RLS / role gates =====
  insert into leads(org_id,name,mobile) values (v_org,'__T_rls','9333333301') returning id into l1;
  insert into leads(org_id,customer_id,name,mobile) values (v_org,v_custid,'__T_rls_cust','9333333302') returning id into v_custlead;
  for rec in select * from (values ('master',v_master),('sales_admin',v_sales),('operation_admin',v_ops),('technician',v_tech),('customer',v_cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    select count(*) into n from lead_followups;
    select count(*) into n2 from lead_outcomes;
    perform pg_temp.chk('RLS '||rec.role||': sees follow-ups/outcomes only if master|sales_admin', (n>0 and n2>0) = (rec.role in ('master','sales_admin')), 'followups='||n||' outcomes='||n2);
    begin perform list_followups('all'); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('RPC list_followups '||rec.role, b = (rec.role in ('master','sales_admin')));
    begin perform log_lead_outcome(l1, o_asked, null, 'call', now()+interval '1 day'); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('RPC log_lead_outcome '||rec.role, b = (rec.role in ('master','sales_admin')));
    begin perform add_lead_note(l1,'x'); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('RPC add_lead_note '||rec.role, b = (rec.role in ('master','sales_admin')));
    begin perform lead_timeline(l1); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('RPC lead_timeline '||rec.role, b = (rec.role in ('master','sales_admin')));
    begin perform followup_counts(); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('RPC followup_counts '||rec.role, b = (rec.role in ('master','sales_admin')));
    begin insert into lead_followups(org_id,lead_id,due_at,status,cancelled_at) values (v_org,v_custlead,now()+interval '9 days','cancelled',now()); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('direct INSERT lead_followups blocked '||rec.role, b=false);
    begin update lead_followups set note='tamper'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('direct UPDATE lead_followups blocked '||rec.role, b=false);
    begin delete from lead_followups; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('direct DELETE lead_followups blocked '||rec.role, b=false);
    begin update lead_activities set note='tamper'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('direct UPDATE lead_activities blocked '||rec.role, b=false);
    begin delete from lead_activities; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('direct DELETE lead_activities blocked '||rec.role, b=false);
    begin update lead_outcomes set label_en = label_en || '!' where code='asked_price'; get diagnostics n = row_count; b:=(n>0); exception when others then b:=false; end;
    perform pg_temp.chk('lead_outcomes edit only master '||rec.role, b = (rec.role='master'));
    begin update settings set lead_stuck_postpones = 3; get diagnostics n=row_count; b := (n>0); exception when others then b:=false; end;
    perform pg_temp.chk('settings.lead_* edit only master '||rec.role, b = (rec.role='master'));
    begin perform delete_lead(l1); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('delete_lead only master '||rec.role, b = (rec.role='master'));
    perform pg_temp.as_pg();
    if not exists (select 1 from leads where id=l1) then insert into leads(id,org_id,name,mobile) values (l1,v_org,'__T_rls','9333333301'); end if;
  end loop;
  -- direct INSERT lead_activities: sales/master/ops/customer must fail; technician only on own leads (policy), not on this lead
  for rec in select * from (values ('master',v_master),('sales_admin',v_sales),('operation_admin',v_ops),('technician',v_tech),('customer',v_cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin insert into lead_activities(org_id,lead_id,type,note) values (v_org,l1,'note','forged'); b:=true; exception when others then b:=false; end;
    perform pg_temp.chk('direct INSERT lead_activities on someone else''s lead blocked '||rec.role, b=false);
    perform pg_temp.as_pg();
  end loop;

  -- timeline sample for a lead that went through reschedule + outcomes
  perform pg_temp.as_user(v_sales);
  insert into pg_temp.res(line) select 'INFO  timeline(l5): '||count(*)||' events; kinds='||string_agg(distinct kind, ',') from lead_timeline(l5);
  perform pg_temp.as_pg();
  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
