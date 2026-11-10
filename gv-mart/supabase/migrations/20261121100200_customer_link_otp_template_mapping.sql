-- 20261121100200_customer_link_otp_template_mapping.sql
--
-- Phase 3 continuation, docs/DECISIONS.md section 10. Wires the `customer_link_otp` event to the
-- real, owner-confirmed WhatsApp template -- the LAST step in this feature's template plumbing,
-- deliberately ordered AFTER 20261121100100_customer_link_otp_dispatch_hardening.sql so file
-- ordering itself enforces that this feature's redaction coverage is in place before any mapping
-- that could ever cause a real template send to exist. `guard_secret_ref_type_template_mapping`
-- (20261120100200_whatsapp_outbox_secret_payload_scrub.sql, committed by a concurrent session, NOT
-- edited here) already refuses to let this insert succeed unless `customer_link_otp` is registered
-- with `redaction_covered = true` in `whatsapp_payload_secret_ref_types` -- confirmed it already is
-- (that migration's own insert); this migration relies on that guard firing for real, not just on
-- reading its code.
--
-- Template facts, owner-confirmed directly from the live Wasi template edit form (2026-10-30, not
-- guessed, not re-derived from any sync job -- the live `whatsapp_wasi_templates` mirror has empty
-- `param_keys` for this template, confirmed read-only, which is why these facts could not come from
-- the database and had to come from the owner):
--   - `lexdraft_otp`, category Authentication, language `en` (matches the live mirror row), status
--     approved.
--   - Body is Meta-generated, not editable: "Your verification code is *{{1}}*." plus an optional
--     security-disclaimer line and an optional expiry line whose presence is not guaranteed --
--     nothing in this migration or the dispatcher depends on those two optional lines existing.
--   - Brand check: PASSED (Meta-generated body, no third-party brand text — the owner's original
--     concern about the name "lexdraft" was about ownership of the WhatsApp Business Account, not
--     the message content, and the owner separately confirmed this account is the right one).
--   - Exactly one Copy Code button. Per the owner's explicit instruction and Meta's own documented
--     shape for this button type, the send payload needs the code in BOTH the body component AND
--     the button component (sub_type "url", index "0", text = the code) -- built in
--     wa-send-core.ts's `buildTemplateRequest` (this phase's own commit) via the new
--     `has_auth_copy_code_button` column below, which duplicates the single resolved body param
--     into a `components` array on the outgoing request. That `components` array is NEVER
--     persisted to `whatsapp_outbox` (same as `headerMediaUrl` already isn't) -- only the flat
--     `params` map is, and that is already covered end-to-end by the reconciled redaction design in
--     20261121100100.
--
-- NOT proof the feature works end-to-end -- per the owner's own explicit instruction, that is only
-- proven by the owner's own later live phone test (a separately-gated step, not run by this
-- migration or this phase). This migration is a pure data change (one row + one new column),
-- exactly as the dispatcher-side code was already built to expect (wa-event-context.ts's
-- `vars.code` wiring, phase 2) -- no application code depends on this migration existing to keep
-- working; everything else in this feature functions identically whether or not this row exists.

do $mig$
begin
  if to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'customer_link_otp_template_mapping: whatsapp_event_templates missing -- base schema not applied';
  end if;

  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'customer_link_otp_template_mapping: whatsapp_payload_secret_ref_types missing -- 20261120100200 not applied first';
  end if;

  if not exists (
    select 1 from public.whatsapp_payload_secret_ref_types
    where ref_type = 'customer_link_otp' and redaction_covered = true
  ) then
    raise exception 'customer_link_otp_template_mapping: customer_link_otp is not registered as redaction_covered -- refusing to map a template to it';
  end if;

  -- 1. New column, additive, defaults false (every existing mapping row is unaffected).
  alter table public.whatsapp_event_templates
    add column if not exists has_auth_copy_code_button boolean not null default false;

  -- 2. The mapping row itself. One per organisation, same pattern as the po.quote_request /
  -- test.hello mappings (20261016320000_wa_dispatch_v2_alerts_and_mappings.sql). param_map key "1"
  -- matches Meta's own positional placeholder numbering ({{1}}) for this template's single body
  -- parameter; "code" is the variable key wa-event-context.ts already populates for
  -- ref_type = 'customer_link_otp' (phase 2). This insert itself is the thing
  -- `guard_secret_ref_type_template_mapping` evaluates -- it will raise and roll back this whole
  -- migration if that guard's precondition is ever false, which is exactly the mechanical
  -- enforcement this migration's own file ordering is meant to rely on, not just reasoning about it.
  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map, has_auth_copy_code_button)
  select o.id, 'customer_link_otp', 'en', 'lexdraft_otp', '{"1": "code"}'::jsonb, true
  from public.organizations o
  on conflict (org_id, event_key, language) do update
    set wasi_template_name = excluded.wasi_template_name,
        param_map = excluded.param_map,
        has_auth_copy_code_button = excluded.has_auth_copy_code_button;

  -- 3. Assertions.
  if not exists (
    select 1 from public.whatsapp_event_templates
    where event_key = 'customer_link_otp' and language = 'en' and wasi_template_name = 'lexdraft_otp'
      and has_auth_copy_code_button = true and param_map = '{"1": "code"}'::jsonb
  ) then
    raise exception 'assertion failed: customer_link_otp -> lexdraft_otp mapping row is missing or wrong';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'whatsapp_event_templates' and column_name = 'has_auth_copy_code_button'
  ) then
    raise exception 'assertion failed: has_auth_copy_code_button column was not created';
  end if;
end
$mig$;
