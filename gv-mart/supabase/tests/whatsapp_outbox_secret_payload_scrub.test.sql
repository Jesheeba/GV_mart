-- Rolled-back test for 20261120100200_whatsapp_outbox_secret_payload_scrub.sql. The runner
-- concatenates that migration file in front of this block in ONE transaction; this block ends in
-- RAISE EXCEPTION, so nothing is committed regardless of pass/fail. Throwaway __TEST_
-- organisation and outbox/template rows only -- this migration touches two pre-existing,
-- real-data-bearing tables (whatsapp_outbox, whatsapp_event_templates), so every row this test
-- writes is tagged __TEST_ and scoped to its own throwaway org, never touching any real row.
do $t$
declare
  res text := '';
  v_org uuid;
  v_otp_row_id uuid;
  v_other_row_id uuid;
  v_payload jsonb;
  v_params jsonb;
begin
  insert into organizations(name) values ('__TEST_wa_outbox_scrub_org') returning id into v_org;

  -- ===== S1: a pending customer_link_otp row keeps its code/template_params while pending =====
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, template, payload, template_params, ref_type, status)
  values (v_org, 'outbound', '9000000099', '__TEST_tmpl', jsonb_build_object('body', '123456 is your code', 'code', '123456'), jsonb_build_object('code', '123456'), 'customer_link_otp', 'pending')
  returning id into v_otp_row_id;
  select payload, template_params into v_payload, v_params from public.whatsapp_outbox where id = v_otp_row_id;
  res := res || E'\n' || case when v_payload ? 'code' and v_params ? 'code'
    then 'ok   S1 pending customer_link_otp row keeps code/template_params untouched' else 'FAIL S1' end;

  -- ===== S2: transitioning that same row to 'sent' scrubs both payload.code and template_params =====
  update public.whatsapp_outbox set status = 'sent' where id = v_otp_row_id;
  select payload, template_params into v_payload, v_params from public.whatsapp_outbox where id = v_otp_row_id;
  res := res || E'\n' || case when not (v_payload ? 'code') and v_params is null
    then 'ok   S2 transition to sent scrubs payload.code and nulls template_params'
    else 'FAIL S2 payload=' || v_payload::text || ' params=' || coalesce(v_params::text, 'null') end;
  res := res || E'\n' || case when v_payload ->> 'body' = '123456 is your code'
    then 'ok   S2b scrub does not touch payload.body (application-level redaction owns that key; this trigger is scoped to template_params + payload.code only)'
    else 'FAIL S2b body unexpectedly changed: ' || coalesce(v_payload ->> 'body', '(null)') end;

  -- ===== S3: a 'failed' (otp_expired_or_used) transition also scrubs =====
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, template, payload, template_params, ref_type, status)
  values (v_org, 'outbound', '9000000098', '__TEST_tmpl', jsonb_build_object('body', '654321 is your code', 'code', '654321'), jsonb_build_object('code', '654321'), 'customer_link_otp', 'pending')
  returning id into v_otp_row_id;
  update public.whatsapp_outbox set status = 'failed', error = 'otp_expired_or_used' where id = v_otp_row_id;
  select payload, template_params into v_payload, v_params from public.whatsapp_outbox where id = v_otp_row_id;
  res := res || E'\n' || case when not (v_payload ? 'code') and v_params is null
    then 'ok   S3 transition to failed/otp_expired_or_used also scrubs' else 'FAIL S3' end;

  -- ===== S4: a row for an unregistered ref_type (e.g. service_ticket) is never touched =====
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, template, payload, template_params, ref_type, status)
  values (v_org, 'outbound', '9000000097', '__TEST_tmpl', jsonb_build_object('body', 'hello'), jsonb_build_object('name', 'x'), 'service_ticket', 'pending')
  returning id into v_other_row_id;
  update public.whatsapp_outbox set status = 'sent' where id = v_other_row_id;
  select payload, template_params into v_payload, v_params from public.whatsapp_outbox where id = v_other_row_id;
  res := res || E'\n' || case when v_payload ->> 'body' = 'hello' and v_params ->> 'name' = 'x'
    then 'ok   S4 an unregistered ref_type is never scrubbed' else 'FAIL S4' end;

  -- ===== S5: the registry row for customer_link_otp exists and is covered (this migration's own insert) =====
  res := res || E'\n' || case when exists (
    select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true
  ) then 'ok   S5 registry row for customer_link_otp exists and is marked covered' else 'FAIL S5' end;

  -- ===== S6: the guard refuses mapping a template to a secret ref_type with redaction_covered = false =====
  update public.whatsapp_payload_secret_ref_types set redaction_covered = false where ref_type = 'customer_link_otp';
  begin
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name)
    values (v_org, 'customer_link_otp', 'en', '__TEST_some_template');
    res := res || E'\nFAIL S6 guard allowed mapping a template to an uncovered secret ref_type';
  exception when others then
    res := res || E'\n' || case when sqlerrm like 'guard_secret_ref_type_template_mapping%'
      then 'ok   S6 guard refuses mapping when redaction_covered = false (' || sqlerrm || ')'
      else 'FAIL S6 unexpected error: ' || sqlerrm end;
  end;
  update public.whatsapp_payload_secret_ref_types set redaction_covered = true where ref_type = 'customer_link_otp';

  -- ===== S7: with redaction_covered = true (the live post-apply state), the guard allows mapping =====
  -- (not committed either way -- this whole test rolls back -- but proves the guard does not
  -- block the eventual, separately-gated lexdraft_otp mapping once the owner confirms it)
  begin
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name)
    values (v_org, 'customer_link_otp', 'en', '__TEST_some_template');
    res := res || E'\nok   S7 guard allows mapping once redaction_covered = true';
  exception when others then
    res := res || E'\nFAIL S7 guard unexpectedly refused: ' || sqlerrm;
  end;

  -- ===== S8: an event_key outside the registry (e.g. service_ticket) is unaffected by the guard =====
  begin
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name)
    values (v_org, 'service_ticket', 'en', '__TEST_some_other_template');
    res := res || E'\nok   S8 an event_key outside the registry is unaffected by the guard';
  exception when others then
    res := res || E'\nFAIL S8 unexpected error: ' || sqlerrm;
  end;

  -- ===== G1: anon/authenticated cannot execute either new trigger function directly =====
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
    then 'ok   G1 scrub_whatsapp_outbox_secret_payload is not directly executable by anon/authenticated' else 'FAIL G1' end;
  res := res || E'\n' || case when not has_function_privilege('anon', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')
    then 'ok   G2 guard_secret_ref_type_template_mapping is not directly executable by anon/authenticated' else 'FAIL G2' end;
  res := res || E'\n' || case when not has_table_privilege('anon', 'public.whatsapp_payload_secret_ref_types', 'SELECT')
    and not has_table_privilege('authenticated', 'public.whatsapp_payload_secret_ref_types', 'SELECT')
    then 'ok   G3 whatsapp_payload_secret_ref_types has no anon/authenticated SELECT grant' else 'FAIL G3' end;

  raise exception E'RESULTS:%', res;
end
$t$;
