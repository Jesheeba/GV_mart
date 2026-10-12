-- Rolled-back DB test for 20261016300000_wa_dispatch_v2_schema.sql + 20261016310000_wa_dispatch_v2_pending_normalisation.sql.
-- Runner: BEGIN; migration 1; migration 2; this block. Throwaway __TEST_ organisation only; ends in a RAISE so nothing is kept.
-- Covers: widened status CHECK, wa_touch_contact (last 10 digits, greatest), the pending normalisation (flag off = inert,
-- flag on = only dispatched ref types, never rows with a wamid), the milestone triggers no longer writing 'sent', the atomic
-- claim, and that wa_touch_contact is not executable by clients.
do $t$
declare
  res text := '';
  v_org uuid;
  v_cust uuid;
  v_tk uuid;
  v_id uuid;
  v_st text;
  n int;
  v_at timestamptz;
begin
  insert into organizations(name) values ('__TEST_wa_dispatch_v2') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;
  insert into customers(org_id, name, mobile) values (v_org, '__TEST_c', '9000000001') returning id into v_cust;

  -- 1. status CHECK
  begin
    insert into whatsapp_outbox(org_id, direction, template, status) values (v_org, 'outbound', 't.pending', 'pending');
    insert into whatsapp_outbox(org_id, direction, template, status) values (v_org, 'outbound', 't.skipped', 'skipped_no_template');
    res := res || E'\nok   status accepts pending and skipped_no_template';
  exception when others then res := res || E'\nFAIL status widening: ' || sqlerrm; end;
  begin
    insert into whatsapp_outbox(org_id, direction, template, status) values (v_org, 'outbound', 't.bogus', 'bogus');
    res := res || E'\nFAIL status accepted a bogus value';
  exception when check_violation then res := res || E'\nok   status still rejects unknown values'; end;
  begin
    insert into whatsapp_outbox(org_id, direction, template, status, delivery_status) values (v_org, 'outbound', 't.d', 'sent', 'teleported');
    res := res || E'\nFAIL delivery_status accepted a bogus value';
  exception when check_violation then res := res || E'\nok   delivery_status rejects unknown values'; end;

  -- 2. wa_touch_contact: last 10 digits, greatest
  perform wa_touch_contact(v_org, '919000000009', '2026-10-12 10:00:00+00');
  perform wa_touch_contact(v_org, '9000000009', '2026-10-12 09:00:00+00');   -- older: must not move it back
  select last_inbound_at into v_at from whatsapp_contacts where org_id = v_org and phone = '9000000009';
  res := res || E'\n' || case when v_at = '2026-10-12 10:00:00+00' then 'ok   wa_touch_contact keys on last 10 digits and keeps the greatest time' else 'FAIL wa_touch_contact ' || coalesce(v_at::text, 'null') end;
  select count(*) into n from whatsapp_contacts where org_id = v_org;
  res := res || E'\n' || case when n = 1 then 'ok   91-prefixed and bare number are one contact' else 'FAIL contact rows ' || n end;
  perform wa_touch_contact(v_org, 'abc', now());  -- garbage is ignored, no error
  res := res || E'\nok   wa_touch_contact ignores an unusable number';

  -- 3. normalisation trigger: flag OFF is inert
  update settings set wa_dispatch_v2_enabled = false where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, template, status, ref_type, ref_id)
    values (v_org, 'outbound', 'milestone.booked', 'sent', 'service_ticket', gen_random_uuid()) returning id into v_id;
  select status into v_st from whatsapp_outbox where id = v_id;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   flag off: a milestone row is left exactly as written' else 'FAIL flag off changed status to ' || v_st end;

  -- flag ON
  update settings set wa_dispatch_v2_enabled = true where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, template, status, ref_type, ref_id)
    values (v_org, 'outbound', 'milestone.booked', 'sent', 'service_ticket', gen_random_uuid()) returning id into v_id;
  select status into v_st from whatsapp_outbox where id = v_id;
  res := res || E'\n' || case when v_st = 'pending' then 'ok   flag on: dispatched ref type is normalised to pending' else 'FAIL expected pending, got ' || v_st end;

  insert into whatsapp_outbox(org_id, direction, template, status, ref_type, ref_id, wa_message_id)
    values (v_org, 'outbound', 'milestone.booked', 'sent', 'service_ticket', gen_random_uuid(), 'wamid.TESTONLY') returning id into v_id;
  select status into v_st from whatsapp_outbox where id = v_id;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   a row that already has a WhatsApp id stays sent' else 'FAIL wamid row became ' || v_st end;

  insert into whatsapp_outbox(org_id, direction, template, status, ref_type, ref_id)
    values (v_org, 'outbound', 'po.approved_and_sent', 'sent', 'purchase_order', gen_random_uuid()) returning id into v_id;
  select status into v_st from whatsapp_outbox where id = v_id;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   purchase_order rows (never dispatched) are left alone' else 'FAIL purchase_order became ' || v_st end;

  insert into whatsapp_outbox(org_id, direction, template, status, payload, wa_message_id)
    values (v_org, 'inbound', 'inbound.raw', 'received', '{"from":"919000000001"}'::jsonb, 'wamid.TESTINBOUND') returning id into v_id;
  select status into v_st from whatsapp_outbox where id = v_id;
  res := res || E'\n' || case when v_st = 'received' then 'ok   inbound rows untouched' else 'FAIL inbound became ' || v_st end;

  -- 4. the real milestone trigger no longer writes an optimistic 'sent'
  insert into service_tickets(org_id, customer_id, name_of_complaint, status) values (v_org, v_cust, '__TEST_booked', 'open') returning id into v_tk;
  select status into v_st from whatsapp_outbox where org_id = v_org and ref_id = v_tk and template = 'milestone.booked' limit 1;
  res := res || E'\n' || case when v_st = 'pending' then 'ok   _milestone_ticket_notify output is pending, not sent' when v_st is null then 'FAIL no milestone row was written' else 'FAIL milestone row is ' || v_st end;

  -- 5. claim-before-send is atomic: the second claimant gets nothing
  select id into v_id from whatsapp_outbox where org_id = v_org and ref_id = v_tk and template = 'milestone.booked' limit 1;
  with c as (update whatsapp_outbox set claimed_at = now() where id = v_id and status = 'pending' and claimed_at is null returning id)
    select count(*) into n from c;
  res := res || E'\n' || case when n = 1 then 'ok   first claim wins' else 'FAIL first claim returned ' || n end;
  with c as (update whatsapp_outbox set claimed_at = now() where id = v_id and status = 'pending' and claimed_at is null returning id)
    select count(*) into n from c;
  res := res || E'\n' || case when n = 0 then 'ok   second claim gets nothing (no double send)' else 'FAIL second claim returned ' || n end;

  -- 6. privileges
  res := res || E'\n' || case when not has_function_privilege('authenticated', 'public.wa_touch_contact(uuid, text, timestamptz)', 'execute')
                                 and not has_function_privilege('anon', 'public.wa_touch_contact(uuid, text, timestamptz)', 'execute')
                             then 'ok   wa_touch_contact is not executable by clients' else 'FAIL wa_touch_contact is executable by a client role' end;
  res := res || E'\n' || case when not has_table_privilege('anon', 'public.whatsapp_contacts', 'select')
                                 and not has_table_privilege('anon', 'public.whatsapp_wasi_templates', 'select')
                                 and not has_table_privilege('anon', 'public.whatsapp_event_templates', 'select')
                             then 'ok   anon has no privilege on the three new tables' else 'FAIL anon has a privilege on a new table' end;
  res := res || E'\n' || case when has_table_privilege('authenticated', 'public.whatsapp_contacts', 'select')
                                 and not has_table_privilege('authenticated', 'public.whatsapp_contacts', 'insert')
                                 and not has_table_privilege('authenticated', 'public.whatsapp_wasi_templates', 'insert')
                                 and not has_table_privilege('authenticated', 'public.whatsapp_wasi_templates', 'update')
                             then 'ok   clients can read but never write contacts or the mirrored template list' else 'FAIL client write privilege on a service-owned table' end;

  raise exception E'RESULTS:%', res;
end
$t$;
