-- Rolled-back test for migrations/20261016330000_wa_dispatch_v2_number_scope.sql.
-- Runner: BEGIN; that migration; this block (ends in RAISE). 20261016300000/310000 must already be applied.
-- Throwaway __TEST_ organisation only; rows are inserted as the owner, exactly like the definer milestone writers do.
do $t$
declare
  res text := ''; v_org uuid; v_cust uuid; n int;
  A text := '9000000001'; B text := '9000000002';
  v_id uuid; v_st text;
  function_ok boolean;
begin
  insert into organizations(name) values ('__TEST_wa_scope') returning id into v_org;
  insert into settings(org_id) values (v_org) on conflict (org_id) do nothing;

  -- 0. defaults, constraints
  res := res || E'\n' || case when (select wa_dispatch_v2_scope from settings where org_id = v_org) = 'numbers'
                               and (select wa_dispatch_v2_numbers from settings where org_id = v_org) = '{}'::text[]
                          then 'ok   defaults: scope numbers, empty list' else 'FAIL defaults' end;
  begin
    update settings set wa_dispatch_v2_numbers = array['12345'] where org_id = v_org;
    res := res || E'\nFAIL an invalid number was accepted';
  exception when check_violation then res := res || E'\nok   a non-10-digit entry is refused'; end;
  begin
    update settings set wa_dispatch_v2_scope = 'everyone' where org_id = v_org;
    res := res || E'\nFAIL an unknown scope was accepted';
  exception when check_violation then res := res || E'\nok   an unknown scope is refused'; end;

  -- 1. flag OFF with a populated list: nothing normalised (today's behaviour)
  update settings set wa_dispatch_v2_enabled = false, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = array[A] where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', A, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   flag OFF, listed number: row stays sent (legacy)' else 'FAIL flag OFF ' || v_st end;

  -- 2. flag ON, EMPTY list: nobody
  update settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = '{}' where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', A, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   flag ON + empty list: nobody uses v2 (row stays sent)' else 'FAIL empty list ' || v_st end;

  -- 3. flag ON, list [A]
  update settings set wa_dispatch_v2_numbers = array[A] where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', A, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'pending' then 'ok   flag ON + listed number: normalised to pending (v2)' else 'FAIL listed ' || v_st end;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', '91' || A, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'pending' then 'ok   the 91-prefixed form of the listed number is the same recipient' else 'FAIL 91 form ' || v_st end;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', B, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   flag ON + NON-listed number: row untouched (legacy), exactly as with the flag off' else 'FAIL non-listed ' || v_st end;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', null, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   a row with no number is untouched' else 'FAIL null number ' || v_st end;

  -- 4. rows the trigger must never touch, even for a listed number
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', A, 'po.x', 'purchase_order', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   purchase_order rows (never dispatched) are left alone' else 'FAIL purchase_order ' || v_st end;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status, wa_message_id) values (v_org, 'outbound', A, 'm.x', 'service_ticket', 'sent', 'wamid.SYNTHETIC') returning status into v_st;
  res := res || E'\n' || case when v_st = 'sent' then 'ok   a row that already has a WhatsApp id stays sent' else 'FAIL wamid row ' || v_st end;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'inbound', A, 'inbound.raw', null, 'received') returning status into v_st;
  res := res || E'\n' || case when v_st = 'received' then 'ok   inbound rows are untouched' else 'FAIL inbound ' || v_st end;

  -- 5. scope org is explicit and covers everyone
  update settings set wa_dispatch_v2_scope = 'org', wa_dispatch_v2_numbers = '{}' where org_id = v_org;
  insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org, 'outbound', B, 'm.x', 'service_ticket', 'sent') returning status into v_st;
  res := res || E'\n' || case when v_st = 'pending' then 'ok   scope org: everyone uses v2 (explicit choice)' else 'FAIL scope org ' || v_st end;

  -- 6. another organisation is unaffected by this one's settings
  declare v_org2 uuid; begin
    insert into organizations(name) values ('__TEST_wa_scope_other') returning id into v_org2;
    insert into settings(org_id) values (v_org2) on conflict (org_id) do nothing;
    insert into whatsapp_outbox(org_id, direction, to_mobile, template, ref_type, status) values (v_org2, 'outbound', B, 'm.x', 'service_ticket', 'sent') returning status into v_st;
    res := res || E'\n' || case when v_st = 'sent' then 'ok   another organisation (flag off) is unaffected' else 'FAIL other org ' || v_st end;
  end;

  -- 7. the helper function
  update settings set wa_dispatch_v2_enabled = true, wa_dispatch_v2_scope = 'numbers', wa_dispatch_v2_numbers = array[A] where org_id = v_org;
  function_ok := wa_dispatch_v2_applies(v_org, A) and wa_dispatch_v2_applies(v_org, '+91 ' || A)
                 and not wa_dispatch_v2_applies(v_org, B) and not wa_dispatch_v2_applies(v_org, null)
                 and not wa_dispatch_v2_applies(gen_random_uuid(), A);
  res := res || E'\n' || case when function_ok then 'ok   wa_dispatch_v2_applies truth table (listed, +91, other, null, unknown org)' else 'FAIL applies()' end;
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.wa_dispatch_v2_applies(uuid,text)', 'execute')
                              and not has_function_privilege('authenticated', 'public.wa_dispatch_v2_applies(uuid,text)', 'execute')
                              and has_function_privilege('service_role', 'public.wa_dispatch_v2_applies(uuid,text)', 'execute')
                         then 'ok   applies() is service_role only' else 'FAIL applies() acl' end;

  -- 8. the real organisation is untouched by the migration: flag off, scope numbers, empty list
  select count(*) into n from settings s join organizations o on o.id = s.org_id
   where o.name not like '\_\_TEST\_%' escape '\' and (s.wa_dispatch_v2_enabled or s.wa_dispatch_v2_scope <> 'numbers' or s.wa_dispatch_v2_numbers <> '{}');
  res := res || E'\n' || case when n = 0 then 'ok   real organisation: flag off, scope numbers, list empty (no change in behaviour)' else 'FAIL real org settings changed' end;

  raise exception E'RESULTS:%', res;
end
$t$;
