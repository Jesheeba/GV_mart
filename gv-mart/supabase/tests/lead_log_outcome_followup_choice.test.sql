-- Rolled-back DB tests for migration 20261012120000_log_outcome_followup_choice (batch-17 item 17).
-- One transaction ending in RAISE; read RESULTS in the error. Uses a throwaway __TEST_ organisation created inside the
-- transaction, so nothing persists and no real lead is read or written.
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
  v_org uuid; v_master uuid; txt text; b boolean; n int; r jsonb;
  o_req uuid; o_opt uuid; o_lost uuid; l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid;
  due timestamptz := now() + interval '2 days';
begin
  insert into organizations (name) values ('__TEST_b17_outcome') returning id into v_org;
  v_master := pg_temp.mkuser('master', v_org);
  select id into o_req from lead_outcomes where org_id = v_org and code = 'asked_price';
  select id into o_lost from lead_outcomes where org_id = v_org and code = 'not_interested';
  insert into lead_outcomes (org_id, code, label_en, label_ta, followup_mode, requires_followup, stage_effect, default_followup_type)
    values (v_org, '__test_info_only', 'Info only', 'தகவல் மட்டும்', 'none', false, null, 'call') returning id into o_opt;
  perform pg_temp.chk('seeded outcomes exist for the test org', o_req is not null and o_lost is not null);

  perform pg_temp.chk('exactly one log_lead_outcome signature', (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='log_lead_outcome')=1);
  perform pg_temp.chk('it has the new p_followup_needed parameter', exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname='log_lead_outcome' and proargnames @> array['p_followup_needed']));
  perform pg_temp.chk('ACL: authenticated + service_role can execute, anon and PUBLIC cannot',
    has_function_privilege('authenticated', (select oid from pg_proc where pronamespace='public'::regnamespace and proname='log_lead_outcome'), 'execute')
    and has_function_privilege('service_role', (select oid from pg_proc where pronamespace='public'::regnamespace and proname='log_lead_outcome'), 'execute')
    and not has_function_privilege('anon', (select oid from pg_proc where pronamespace='public'::regnamespace and proname='log_lead_outcome'), 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace='public'::regnamespace and p.proname='log_lead_outcome' and a.grantee = 0));

  -- leads (each gets an open initial follow-up from the insert trigger)
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l1','9200000001') returning id into l1;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l2','9200000002') returning id into l2;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l3','9200000003') returning id into l3;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l4','9200000004') returning id into l4;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l5','9200000005') returning id into l5;
  insert into leads (org_id,name,mobile) values (v_org,'__TEST_l6','9200000006') returning id into l6;
  perform pg_temp.chk('each new lead has one open follow-up', (select count(*) from lead_followups where lead_id in (l1,l2,l3,l4,l5,l6) and status='open')=6);

  perform pg_temp.as_user(v_master);

  -- 1. old-style call (9 positional args): unchanged behaviour
  begin perform log_lead_outcome(l1, o_req, 'x', 'call', null); b := true; exception when others then b := false; end;
  perform pg_temp.chk('old-style call: requires_followup outcome without a date still raises', b = false);
  r := log_lead_outcome(l1, o_req, 'asked the price', 'call', due, 'send_quote');
  perform pg_temp.chk('old-style call: schedules the next follow-up as before', (r->>'followup_id') is not null and (r->>'followup_needed')::boolean = true);
  perform pg_temp.as_pg();
  perform pg_temp.chk('old-style call: exactly one open follow-up, lead open', (select count(*) from lead_followups where lead_id=l1 and status='open')=1 and (select status::text from leads where id=l1)='contacted');
  perform pg_temp.as_user(v_master);

  -- 2. "No": no date needed, lead stays open, no open follow-up, shows in the No follow-up list
  r := log_lead_outcome(l2, o_req, E'Spoke to the owner.\nWants to ask the family first.\nNo date to give.', 'call', null, null, null, false, null, false);
  perform pg_temp.chk('followup_needed=false: no date required, no follow-up created', (r->>'followup_id') is null and (r->>'followup_needed')::boolean = false and (r->>'next_due_at') is null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('No: the lead is still open (not won/lost)', (select status::text from leads where id=l2) not in ('won','lost'));
  perform pg_temp.chk('No: the contact still completed the open follow-up and none is left', (select count(*) from lead_followups where lead_id=l2 and status='open')=0 and (select count(*) from lead_followups where lead_id=l2 and status='done')=1);
  perform pg_temp.chk('No: the multi-line note is stored verbatim', (select note from lead_activities where lead_id=l2 and outcome_id=o_req)=E'Spoke to the owner.\nWants to ask the family first.\nNo date to give.');
  perform pg_temp.chk('No: the stage effect of the outcome still applies', (select status::text from leads where id=l2)='contacted');
  perform pg_temp.as_user(v_master);
  perform pg_temp.chk('No: the lead appears in list_leads_without_followup', exists (select 1 from list_leads_without_followup() x where x.lead_id=l2));
  perform pg_temp.chk('No: the lead is gone from list_followups', not exists (select 1 from list_followups('all') x where x.lead_id=l2));

  -- 3. explicit "Yes" on an outcome that does not require a follow-up
  begin perform log_lead_outcome(l3, o_opt, 'n', 'call', null, null, null, false, null, true); b := true; exception when others then b := false; end;
  perform pg_temp.chk('followup_needed=true with no date raises', b = false);
  r := log_lead_outcome(l3, o_opt, 'will check back', 'call', due, 'whatsapp', null, false, null, true);
  perform pg_temp.chk('followup_needed=true on an optional outcome schedules one', (r->>'followup_id') is not null);
  perform pg_temp.as_pg();
  perform pg_temp.chk('Yes on optional outcome: one open follow-up of the chosen type', (select count(*) from lead_followups where lead_id=l3 and status='open' and type::text='whatsapp')=1);
  perform pg_temp.as_user(v_master);

  -- 4. NULL = outcome default (optional outcome -> none; required outcome -> needs a date)
  r := log_lead_outcome(l4, o_opt, 'just info', 'call');
  perform pg_temp.chk('NULL on an optional outcome: no follow-up', (r->>'followup_id') is null and (r->>'followup_needed')::boolean = false);
  begin perform log_lead_outcome(l5, o_req, 'x', 'call', null, null, null, false, null, null); b := true; exception when others then b := false; end;
  perform pg_temp.chk('explicit NULL on a required outcome still needs a date', b = false);

  -- 5. a closing outcome never schedules one, whatever is passed
  r := log_lead_outcome(l6, o_lost, null, 'call', due, 'call', null, false, 'Not interested', true);
  perform pg_temp.chk('closing outcome ignores followup_needed=true', (r->>'followup_id') is null and (r->>'status')='lost');
  perform pg_temp.as_pg();
  perform pg_temp.chk('closed lead has no open follow-up', (select count(*) from lead_followups where lead_id=l6 and status='open')=0);
  perform pg_temp.as_user(v_master);

  -- 6. note length cap
  begin perform log_lead_outcome(l5, o_opt, repeat('x', 2001), 'call', null, null, null, false, null, false); b := true; exception when others then b := false; end;
  perform pg_temp.chk('a 2001-character note is rejected', b = false);
  begin perform log_lead_outcome(l5, o_opt, repeat('x', 2000), 'call', null, null, null, false, null, false); b := true; exception when others then b := false; end;
  perform pg_temp.chk('a 2000-character note is accepted', b);
  perform pg_temp.as_pg();
  perform pg_temp.chk('the failed 2001-character call left nothing behind', (select count(*) from lead_activities where lead_id=l5 and length(note)=2001)=0);

  -- 7. non-staff cannot call it
  perform pg_temp.as_user(pg_temp.mkuser('customer', v_org));
  begin perform log_lead_outcome(l5, o_opt, 'x', 'call', null, null, null, false, null, false); b := true; exception when others then b := false; end;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a customer-role user cannot log an outcome', b = false);

  select string_agg(r2.line, E'\n' order by r2.n) into txt from pg_temp.res r2;
  raise exception E'RESULTS\n%', txt;
end $t$;
