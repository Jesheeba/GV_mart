-- Rolled-back DB tests for Phase 2 gap 3 (migration 20261008130000_lead_assignment). Runs entirely in throwaway organisations; ends in a RAISE.
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
  v_org uuid; v_other_org uuid; m uuid; s1 uuid; s2 uuid; s3 uuid; ops uuid; tech uuid; cust uuid; foreign_s uuid;
  a uuid; b uuid; c uuid; d uuid; e uuid; closed uuid;
  txt text; ok boolean; n int; r jsonb; rec record; v_body text; cnt jsonb;
begin
  -- A throwaway organisation: no real lead, follow-up, notification or log row is read or written.
  insert into organizations (name) values ('__TEST_assign_org') returning id into v_org;
  insert into organizations (name) values ('__TEST_assign_org_other') returning id into v_other_org;
  m := pg_temp.mkuser('master', v_org); s1 := pg_temp.mkuser('sales_admin', v_org); s2 := pg_temp.mkuser('sales_admin', v_org);
  s3 := pg_temp.mkuser('sales_admin', v_org); ops := pg_temp.mkuser('operation_admin', v_org); tech := pg_temp.mkuser('technician', v_org);
  cust := pg_temp.mkuser('customer', v_org); foreign_s := pg_temp.mkuser('sales_admin', v_other_org);
  update profiles set is_active = false where id = s3;

  insert into leads(org_id,name,mobile) values (v_org,'__TEST_a','9888888801') returning id into a;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_b','9888888802') returning id into b;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_c','9888888803') returning id into c;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_d','9888888804') returning id into d;
  insert into leads(org_id,name,mobile) values (v_org,'__TEST_e','9888888805') returning id into e;
  insert into leads(org_id,name,mobile,status) values (v_org,'__TEST_closed','9888888806','lost') returning id into closed;
  perform pg_temp.chk('new leads are unassigned', (select count(*) from leads where org_id=v_org and assigned_to is not null)=0);

  -- ===== who may call assign_lead =====
  for rec in select * from (values ('operation_admin',ops),('technician',tech),('customer',cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin perform assign_lead(a, s1); ok:=true; exception when others then ok:=false; end;
    perform pg_temp.chk('assign_lead rejected for '||rec.role, ok=false);
    perform pg_temp.as_pg();
  end loop;
  begin execute 'set local role anon'; perform assign_lead(a, s1); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('assign_lead rejected for anon', ok=false);

  -- ===== master =====
  perform pg_temp.as_user(m);
  r := assign_lead(a, s1, 'regional lead');
  perform pg_temp.as_pg();
  perform pg_temp.chk('master assigns a lead to a sales_admin', (select assigned_to from leads where id=a)=s1 and r->>'assigned_to'=s1::text);
  perform pg_temp.chk('assignment logged (from null, to s1, by master, with reason)', (select count(*) from lead_assignments where lead_id=a and from_user is null and to_user=s1 and assigned_by=m and reason='regional lead')=1);
  perform pg_temp.chk('assignee got a lead_assigned notification', (select count(*) from notifications where org_id=v_org and user_id=s1 and type='lead_assigned' and ref_id=a)=1);
  perform pg_temp.as_user(m);
  r := assign_lead(a, s2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('master reassigns s1 -> s2; log has from=s1 to=s2', (select assigned_to from leads where id=a)=s2 and (select count(*) from lead_assignments where lead_id=a and from_user=s1 and to_user=s2)=1);
  perform pg_temp.as_user(m);
  begin perform assign_lead(a, s2); ok:=true; exception when others then ok:=sqlerrm not like '%already%'; end;
  perform pg_temp.chk('assigning to the current assignee is rejected', ok=false);
  begin perform assign_lead(a, s3); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('assignee must be ACTIVE (deactivated s3 rejected)', ok=false);
  begin perform assign_lead(a, ops); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('assignee must be master/sales_admin (operation_admin rejected)', ok=false);
  begin perform assign_lead(a, tech); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('technician rejected as assignee', ok=false);
  begin perform assign_lead(a, foreign_s); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('assignee from another organisation rejected', ok=false);
  begin perform assign_lead(closed, s1); ok:=true; exception when others then ok:=sqlerrm not like '%open lead%'; end;
  perform pg_temp.chk('closed lead cannot be assigned', ok=false);
  r := assign_lead(a, m);
  perform pg_temp.chk('master may assign to themselves', (select assigned_to from leads where id=a)=m);
  select count(*) into n from notifications where org_id=v_org and user_id=m and type='lead_assigned';
  perform pg_temp.chk('no notification when assigning to yourself', n=0);
  r := assign_lead(a, null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('master can unassign (to NULL), logged', (select assigned_to from leads where id=a) is null and (select count(*) from lead_assignments where lead_id=a and to_user is null)=1);

  -- ===== sales_admin rules =====
  perform pg_temp.as_user(s1);
  begin perform assign_lead(b, s2); ok:=true; exception when others then ok:=sqlerrm not like '%pick up%'; end;
  perform pg_temp.chk('sales_admin cannot assign an unassigned lead to a colleague (only pick it up)', ok=false);
  r := assign_lead(b, s1);
  perform pg_temp.chk('sales_admin picks up an unassigned lead for themselves', (select assigned_to from leads where id=b)=s1);
  begin perform assign_lead(b, s1); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('hand-over to yourself rejected', ok=false);
  begin perform assign_lead(b, null); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('sales_admin cannot unassign', ok=false);
  begin perform assign_lead(b, s3); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('sales_admin cannot hand over to an inactive colleague', ok=false);
  r := assign_lead(b, s2);
  perform pg_temp.chk('sales_admin hands THEIR OWN lead to a colleague', (select assigned_to from leads where id=b)=s2);
  begin perform assign_lead(b, s1); ok:=true; exception when others then ok:=sqlerrm not like '%someone else%'; end;
  perform pg_temp.chk('sales_admin cannot take a colleague''s lead', ok=false);
  begin perform assign_lead(b, s3); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('sales_admin cannot move a colleague''s lead', ok=false);
  perform pg_temp.as_pg();
  perform pg_temp.chk('handed-over lead: log from=s1 to=s2 by s1; notification to s2', (select count(*) from lead_assignments where lead_id=b and from_user=s1 and to_user=s2 and assigned_by=s1)=1 and (select count(*) from notifications where user_id=s2 and type='lead_assigned' and ref_id=b)=1);
  perform pg_temp.as_user(s1);
  r := assign_lead(c, s1);
  r := assign_lead(c, m);
  perform pg_temp.as_pg();
  perform pg_temp.chk('sales_admin can hand their own lead to the master', (select assigned_to from leads where id=c)=m);

  -- ===== direct writes are blocked (leads_update_sales would otherwise allow them) =====
  for rec in select * from (values ('master',m),('sales_admin',s1)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin update leads set assigned_to = s1 where id = d; get diagnostics n = row_count; ok := n > 0; exception when others then ok:=false; end;
    perform pg_temp.chk('direct UPDATE assigned_to blocked for '||rec.role, ok=false);
    begin insert into leads(org_id,name,mobile,assigned_to) values (v_org,'__TEST_direct','9888888899',s1); ok:=true; exception when others then ok:=false; end;
    perform pg_temp.chk('direct INSERT with assigned_to blocked for '||rec.role, ok=false);
    perform pg_temp.as_pg();
  end loop;
  begin update leads set assigned_to = s1 where id = d; ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('direct UPDATE assigned_to blocked even for the database owner (no flag)', ok=false);
  update leads set assigned_to = assigned_to where id = a;
  perform pg_temp.chk('no-op writes to the column are allowed', true);

  -- ===== append-only log =====
  for rec in select * from (values ('postgres',null::uuid),('master',m)) x(role, uid) loop
    if rec.uid is not null then perform pg_temp.as_user(rec.uid); end if;
    begin update lead_assignments set reason='x' where lead_id=a; get diagnostics n = row_count; ok:=(n>0); exception when others then ok:=false; end;
    perform pg_temp.chk('assignment log UPDATE rejected '||rec.role, ok=false);
    begin delete from lead_assignments where lead_id=a; get diagnostics n = row_count; ok:=(n>0); exception when others then ok:=false; end;
    perform pg_temp.chk('assignment log DELETE rejected '||rec.role, ok=false);
    perform pg_temp.as_pg();
  end loop;
  perform pg_temp.as_user(s1);
  perform pg_temp.chk('sales_admin cannot read the assignment log', (select count(*) from lead_assignments)=0);
  perform pg_temp.as_pg();
  perform pg_temp.as_user(m);
  perform pg_temp.chk('master reads the assignment log', (select count(*) from lead_assignments)>=5);
  perform pg_temp.chk('timeline shows assignment events with names', exists (select 1 from lead_timeline(b) t where t.kind='assignment' and t.detail->>'to_name' is not null and t.detail->>'from_name' is not null));
  perform pg_temp.as_pg();

  -- ===== My Day scopes. State: a unassigned, b -> s2, c -> m, d,e unassigned =====
  perform pg_temp.as_user(s1);
  perform pg_temp.chk('sales_admin auto scope = own + unassigned (not the colleague''s, not master''s)',
    (select array_agg(lead_name order by lead_name) from list_followups()) = array['__TEST_a','__TEST_d','__TEST_e']);
  perform pg_temp.chk('OLD call shape (5 args, no scope) still works', (select count(*) from list_followups('all', null, null, null, false))=3);
  perform pg_temp.chk('mine scope for s1 is empty', (select count(*) from list_followups(p_scope => 'mine'))=0);
  perform pg_temp.chk('unassigned scope', (select count(*) from list_followups(p_scope => 'unassigned'))=3);
  begin perform list_followups(p_scope => 'all'); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('sales_admin cannot ask for scope all', ok=false);
  begin perform list_followups(p_scope => 'person', p_assignee => s2); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('sales_admin cannot ask for a colleague''s leads (person scope)', ok=false);
  cnt := followup_counts();
  perform pg_temp.chk('followup_counts() no-arg call works; sales_admin total = 3 and no per-person split', (cnt->>'total')::int=3 and cnt->'by_person'='[]'::jsonb, cnt::text);
  perform pg_temp.as_pg();

  perform pg_temp.as_user(s2);
  perform pg_temp.chk('s2 sees own lead b + unassigned', (select array_agg(lead_name order by lead_name) from list_followups()) = array['__TEST_a','__TEST_b','__TEST_d','__TEST_e']);
  perform pg_temp.chk('assignee name returned for an assigned lead', (select assignee_name from list_followups(p_scope=>'mine') where lead_name='__TEST_b') like '__T sales_admin');
  perform pg_temp.as_pg();

  perform pg_temp.as_user(m);
  perform pg_temp.chk('master auto scope = all (5 open leads)', (select count(*) from list_followups())=5);
  perform pg_temp.chk('master person scope = s2', (select array_agg(lead_name) from list_followups(p_scope=>'person', p_assignee=>s2))=array['__TEST_b']);
  perform pg_temp.chk('master mine scope', (select array_agg(lead_name) from list_followups(p_scope=>'mine'))=array['__TEST_c']);
  perform pg_temp.chk('master unassigned scope', (select count(*) from list_followups(p_scope=>'unassigned'))=3);
  cnt := followup_counts();
  perform pg_temp.chk('master counts: total 5 with per-person split (s2:1, master:1)', (cnt->>'total')::int=5 and jsonb_array_length(cnt->'by_person')=2, cnt::text);
  begin perform list_followups(p_scope => 'person'); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('person scope without an assignee rejected', ok=false);
  begin perform list_followups(p_scope => 'bogus'); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.chk('invalid scope rejected', ok=false);
  perform pg_temp.as_pg();

  for rec in select * from (values ('operation_admin',ops),('technician',tech),('customer',cust)) x(role, uid) loop
    perform pg_temp.as_user(rec.uid);
    begin perform list_followups(); ok:=true; exception when others then ok:=false; end;
    perform pg_temp.chk('list_followups rejected for '||rec.role, ok=false);
    begin perform followup_counts(); ok:=true; exception when others then ok:=false; end;
    perform pg_temp.chk('followup_counts rejected for '||rec.role, ok=false);
    perform pg_temp.as_pg();
  end loop;
  begin execute 'set local role anon'; perform list_followups(); ok:=true; exception when others then ok:=false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('list_followups rejected for anon', ok=false);

  -- ===== deactivated assignee => lead falls back to "unassigned" for everyone =====
  update profiles set is_active = true where id = s3;
  perform pg_temp.as_user(m); perform assign_lead(e, s3); perform pg_temp.as_pg();
  update profiles set is_active = false where id = s3;
  perform pg_temp.as_user(s1);
  perform pg_temp.chk('lead of a deactivated assignee shows up as unassigned for others', exists (select 1 from list_followups() where lead_name='__TEST_e' and assignee_id is null));
  r := assign_lead(e, s1);
  perform pg_temp.chk('and can be picked up', (select assigned_to from leads where id=e)=s1);
  perform pg_temp.as_pg();

  -- ===== notifications. State: a, d unassigned; b -> s2; c -> m; e -> s1 =====
  delete from lead_notification_log where key like v_org::text || ':%';
  update lead_followups set due_at = '2026-10-04 05:30:00+00' where lead_id in (a, b, c) and status='open';      -- a,b,c: >24h overdue (4 Oct)
  update lead_followups set due_at = '2026-10-14 05:30:00+00' where lead_id in (d, e) and status='open';          -- d,e: due on the run day
  r := run_lead_followup_notifications('2026-10-14 04:30:00+00', v_org);
  perform pg_temp.chk('runner limited to one organisation (returns digests for it only)', (r->>'digests')::int=1, r::text);
  perform pg_temp.chk('digest rows: master, s1, s2 (s3 inactive gets none)', (select count(*) from notifications where org_id=v_org and type='lead_followup_digest')=3 and not exists (select 1 from notifications where org_id=v_org and user_id=s3 and type like 'lead\_followup%'));
  select body into v_body from notifications where org_id=v_org and user_id=s1 and type='lead_followup_digest';
  perform pg_temp.chk('s1 digest = own(e)+unassigned(a,d): 2 due today, 1 overdue; no breakdown', v_body = '2 due today, 1 overdue. Open My Day.', v_body);
  select body into v_body from notifications where org_id=v_org and user_id=s2 and type='lead_followup_digest';
  perform pg_temp.chk('s2 digest = own(b)+unassigned(a,d)', v_body like '1 due today, 2 overdue. Open My Day.', v_body);
  select body into v_body from notifications where org_id=v_org and user_id=m and type='lead_followup_digest';
  perform pg_temp.chk('master digest = everything (5) plus unassigned and per-person split', v_body like '2 due today, 3 overdue. Open My Day. Unassigned: %By person: %', v_body);
  select body into v_body from notifications where org_id=v_org and user_id=s1 and type='lead_followup_overdue';
  perform pg_temp.chk('s1 overdue-24h list: unassigned only (a); e is not overdue', v_body like '1 lead(s): __TEST_a', v_body);
  select body into v_body from notifications where org_id=v_org and user_id=s2 and type='lead_followup_overdue';
  perform pg_temp.chk('s2 overdue-24h list: own b + unassigned a', v_body like '2 lead(s): %__TEST_a%' and v_body like '%__TEST_b%', v_body);
  select body into v_body from notifications where org_id=v_org and user_id=m and type='lead_followup_overdue';
  perform pg_temp.chk('master overdue-24h: unassigned + own list, then per-person counts for others', v_body like '2 lead(s): %' and v_body like '%__TEST_a%' and v_body like '%__TEST_c%' and v_body like '%By person: %', v_body);
  perform pg_temp.chk('master list does not contain a colleague''s lead name (only a count)', (select body not like '%__TEST_b%' from notifications where org_id=v_org and user_id=m and type='lead_followup_overdue'));

  -- reminders: assigned -> assignee only; unassigned -> everyone
  update lead_followups set due_at = '2026-10-14 09:00:00+00', is_exact_time = true where lead_id = b and status='open';
  update lead_followups set due_at = '2026-10-14 09:05:00+00', is_exact_time = true where lead_id = d and status='open';
  r := run_lead_followup_notifications('2026-10-14 08:50:00+00', v_org);
  perform pg_temp.chk('2 reminders sent', (r->>'reminders')::int=2, r::text);
  perform pg_temp.chk('reminder for assigned lead b goes to its assignee only (s2)', (select array_agg(user_id) from notifications where org_id=v_org and type='lead_callback_reminder' and ref_id=b)=array[s2]);
  perform pg_temp.chk('reminder for unassigned lead d goes to master + every active sales_admin (3)', (select count(*) from notifications where org_id=v_org and type='lead_callback_reminder' and ref_id=d)=3);
  -- idempotent
  r := run_lead_followup_notifications('2026-10-14 08:52:00+00', v_org);
  perform pg_temp.chk('rerun sends nothing new', (r->>'reminders')::int=0 and (r->>'digests')::int=0 and (r->>'overdue_lists')::int=0, r::text);

  -- ===== deleting a profile sets assigned_to to NULL without tripping the guard =====
  perform pg_temp.chk('before: b is assigned to s2', (select assigned_to from leads where id=b)=s2);
  delete from notifications where user_id = s2;
  delete from profiles where id = s2;
  perform pg_temp.chk('after the assignee profile is deleted the lead is simply unassigned', (select assigned_to from leads where id=b) is null);
  perform pg_temp.chk('assignment log rows survive (user columns nulled)', (select count(*) from lead_assignments where lead_id=b)=2);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
