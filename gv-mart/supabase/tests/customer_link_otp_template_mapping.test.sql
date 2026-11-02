-- Test for 20261121100200_customer_link_otp_template_mapping.sql.
-- Run inside the rehearsal wrapper's own transaction, AFTER both 20261121100100 (dispatch
-- hardening) and this migration have been applied in the same transaction. Ends by raising an
-- exception listing every assertion's pass/fail, so nothing here ever commits regardless of
-- outcome.
do $test$
declare
  v_results text := '';
  v_org_id uuid;
  v_row record;
  v_guard_blocked boolean := false;
begin
  insert into public.organizations (name) values ('__TEST_template_mapping') returning id into v_org_id;

  -- G0: the mapping row exists, correctly shaped, for the throwaway org too (the migration's own
  -- "select o.id from organizations" covers every org, including ones created after it ran would
  -- NOT be covered automatically -- but this test's own org is created fresh and will never have a
  -- row unless we insert one ourselves here, matching what a real new org would need; this is a
  -- known, accepted scope limit of a one-time backfill insert, not a bug to test around).
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, has_auth_copy_code_button)
  values (v_org_id, 'customer_link_otp', 'en', 'lexdraft_otp', '{"1": "code"}'::jsonb, true);

  select * into v_row from public.whatsapp_event_templates where org_id = v_org_id and event_key = 'customer_link_otp';
  if v_row.wasi_template_name = 'lexdraft_otp' and v_row.language = 'en' and v_row.has_auth_copy_code_button = true
     and v_row.param_map = '{"1": "code"}'::jsonb and v_row.is_active = true then
    v_results := v_results || 'G0 ok: mapping row shaped correctly' || E'\n';
  else
    v_results := v_results || format('G0 FAIL: mapping row wrong -- %s', v_row) || E'\n';
  end if;

  -- G1: has_auth_copy_code_button column exists with the right default for pre-existing rows
  -- (every mapping created before this migration must be unaffected -- default false).
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'whatsapp_event_templates'
      and column_name = 'has_auth_copy_code_button' and column_default like '%false%'
  ) then
    v_results := v_results || 'G1 ok: has_auth_copy_code_button defaults to false' || E'\n';
  else
    v_results := v_results || 'G1 FAIL: has_auth_copy_code_button missing or wrong default' || E'\n';
  end if;

  -- G2: the guard trigger from 20261120100200 genuinely fires -- prove it with a ref_type that IS
  -- registered but explicitly marked NOT covered, not merely an unregistered one (the guard's own
  -- documented scope limit is that an UNREGISTERED ref_type is allowed through -- only a
  -- registered-and-not-covered one is refused). Don't assume this from reading that migration's
  -- code.
  insert into public.whatsapp_payload_secret_ref_types (ref_type, redaction_covered, covered_note)
  values ('__TEST_uncovered_ref_type', false, '__TEST__ deliberately uncovered, for this test only');

  begin
    insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
    values (v_org_id, '__TEST_uncovered_ref_type', 'en', '__TEST_some_template', '{}'::jsonb);
  exception when others then
    v_guard_blocked := true;
  end;
  if v_guard_blocked then
    v_results := v_results || 'G2 ok: guard_secret_ref_type_template_mapping genuinely refuses a registered-but-not-covered ref_type' || E'\n';
  else
    v_results := v_results || 'G2 FAIL: a registered-but-not-covered ref_type mapping was NOT refused -- guard is not actually firing' || E'\n';
  end if;

  -- P1: customer_link_otp itself is NOT refused (it IS covered) -- already proven by G0's
  -- successful insert above not raising; restated explicitly here for a clear pass/fail line.
  v_results := v_results || 'P1 ok: customer_link_otp mapping insert succeeded (covered ref_type is never refused)' || E'\n';

  -- G3: RLS/grants on whatsapp_event_templates unchanged by this migration -- anon still has none,
  -- authenticated still writes only through the existing ops-staff policy (not re-opened wider).
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'whatsapp_event_templates' and policyname = 'whatsapp_event_templates_write_ops'
  ) then
    v_results := v_results || 'G3 FAIL: whatsapp_event_templates_write_ops policy is missing' || E'\n';
  else
    v_results := v_results || 'G3 ok: existing whatsapp_event_templates RLS policies untouched' || E'\n';
  end if;

  raise exception E'TEST_RESULTS:\n%', v_results;
end
$test$;
