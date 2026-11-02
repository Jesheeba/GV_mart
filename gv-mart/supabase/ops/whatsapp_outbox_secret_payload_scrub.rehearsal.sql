-- Rehearsal wrapper for supabase/migrations/20261120100200_whatsapp_outbox_secret_payload_scrub.sql + supabase/tests/whatsapp_outbox_secret_payload_scrub.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
-- except through the project's approved Management-API runner (supabase/ops/run_rehearsal.mjs,
-- sha256-verified before use), and only as a REHEARSAL: this block always ends in RAISE
-- EXCEPTION, so nothing it does can ever commit, regardless of pass/fail.
--
-- This migration touches two pre-existing, real-data-bearing tables (whatsapp_outbox,
-- whatsapp_event_templates) with a BEFORE UPDATE / BEFORE INSERT OR UPDATE trigger each -- the
-- real-row fingerprint below covers both tables' real (non __TEST_) rows, not just the new
-- registry table, specifically to catch any unintended side effect on existing data.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash text := '8533249a1b9441f14fc18867a79f7b1dde53a49df296504aa668135f56f78fd1';
  v_expected_test_hash      text := '529e571339c5f414dae3cc58209746b3820185372853278ee698bcb71c28ea90';
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before           text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_migration   text := $migration$-- Fixes a HIGH finding from the independent security review of the customer-OTP-link fast-dispatch
-- path (docs/DECISIONS.md section 9, Edge Function review): whatsapp_outbox's existing
-- redaction-on-send/redaction-on-give-up logic (wa-milestone-dispatch-core.ts,
-- wa-dispatch-v2.ts) only ever replaces the `payload` column. It never touches
-- `template_params` (added by 20261016300000_wa_dispatch_v2_schema.sql), which
-- wa-send-core.ts's `executeSend` writes unconditionally, BEFORE the send, whenever a row is
-- dispatched through an approved template (`buildTemplateRequest`'s `vars`, which for a
-- `customer_link_otp` row would include the raw 6-digit code under `vars.code` -- wired by
-- wa-event-context.ts specifically so a future template mapping can use it as a named
-- parameter). Today this is NOT exploitable: no `whatsapp_event_templates` row maps
-- `customer_link_otp` to any template (held pending the owner's brand-neutrality check on
-- `lexdraft_otp`, see docs/DECISIONS.md section 9.3), so `plan.kind` can never resolve to
-- `"template"` for this ref_type and `template_params` is never written for it. But the moment
-- that mapping is ever added, every future `customer_link_otp` send would silently start
-- leaving the plaintext code in `template_params` forever, unredacted, readable by the same
-- `whatsapp_outbox_select_staff` policy the whole redaction mechanism exists to defend against.
--
-- This migration closes that gap at the DATABASE layer, not just in application code, so it
-- cannot be reopened by a future code change that forgets the TypeScript-side redaction call:
--   1. A new registry table, `whatsapp_payload_secret_ref_types`, names every `ref_type` whose
--      `whatsapp_outbox.payload` may carry a secret value (today: only `customer_link_otp`, its
--      `code` key) and records whether a DB-level scrub trigger for it is confirmed wired
--      (`redaction_covered`). This migration inserts exactly one row, already covered.
--   2. A BEFORE UPDATE trigger on `whatsapp_outbox`, `scrub_whatsapp_outbox_secret_payload`,
--      fires whenever a row's `ref_type` is in that registry and its `status` is leaving
--      `'pending'` (i.e. a terminal state: sent, failed, or skipped_no_template) -- at that
--      point the code has either been delivered or never will be, so there is nothing left to
--      protect by keeping it. It unconditionally sets `template_params` to NULL and strips any
--      `code` key out of `payload` (defense in depth on top of, not instead of, the existing
--      application-level full-payload-replace redaction -- idempotent and harmless if the
--      application code already did both).
--   3. A BEFORE INSERT OR UPDATE trigger on `whatsapp_event_templates`,
--      `guard_secret_ref_type_template_mapping`, refuses to create or activate a mapping for any
--      `event_key` that appears in the registry with `redaction_covered = false` -- a mechanical
--      guard, not just a code-review convention, against ever wiring a template to a
--      secret-carrying ref_type before its DB-level scrub coverage exists. `customer_link_otp` is
--      inserted already covered (step 1), so this migration does not itself block the eventual
--      `lexdraft_otp` (or replacement) mapping -- that mapping is still withheld for the separate,
--      unrelated reason recorded in DECISIONS.md section 9.3 (unconfirmed brand neutrality), not
--      because of this guard.
--
-- Deliberate scope limit, documented rather than silently assumed: this guard only protects
-- ref_types someone has explicitly registered in `whatsapp_payload_secret_ref_types`. A brand-new
-- secret-carrying ref_type invented in the future and mapped to a template WITHOUT first being
-- added to this registry would not be caught by trigger 3 -- there is no way for a database
-- constraint to infer "this payload might contain a secret" from an arbitrary future ref_type on
-- its own. Guarding against that remains a code-review discipline (the same discipline that
-- caught this gap in the first place), not something this migration claims to close generically.
-- audit_log/error-text check (requested explicitly): read every audit_log insert in
-- request_customer_link_code/verify_customer_link_code (20261120100000_customer_link_otp.sql) --
-- none ever include the code itself, only phone_last4/challenge_id/attempts metadata. No
-- console.log/console.error anywhere in the dispatch path prints payload/body/code (confirmed by
-- the Edge Function review). Nothing further to fix on those two fronts.

-- ── 1. Registry: which ref_types' outbox payload may carry a secret ─────────────────────────
create table if not exists public.whatsapp_payload_secret_ref_types (
  ref_type text primary key,
  redaction_covered boolean not null default false,
  covered_note text,
  created_at timestamptz not null default now()
);

alter table public.whatsapp_payload_secret_ref_types enable row level security;
revoke all on public.whatsapp_payload_secret_ref_types from public, anon, authenticated;
-- No policy for any role: this is an internal trigger-support table, not a UI surface. Read via
-- service_role (migrations, ad-hoc audits) only.

insert into public.whatsapp_payload_secret_ref_types (ref_type, redaction_covered, covered_note)
values (
  'customer_link_otp',
  true,
  'scrub_whatsapp_outbox_secret_payload trigger added in this migration clears template_params '
  || 'and strips payload.code on any non-pending status; application-level full-payload-replace '
  || 'redaction (wa-milestone-dispatch-core.ts, wa-dispatch-v2.ts) already covered payload.body/'
  || 'code, this trigger is defense in depth plus the first thing to actually cover template_params.'
)
on conflict (ref_type) do update set redaction_covered = excluded.redaction_covered, covered_note = excluded.covered_note;

-- ── 2. Scrub trigger on whatsapp_outbox ──────────────────────────────────────────────────────
create or replace function public.scrub_whatsapp_outbox_secret_payload()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.ref_type is null then
    return new;
  end if;
  if old.status = 'pending' and new.status <> 'pending'
     and exists (
       select 1 from public.whatsapp_payload_secret_ref_types
       where ref_type = new.ref_type and redaction_covered = true
     )
  then
    new.template_params := null;
    if new.payload is not null and new.payload ? 'code' then
      new.payload := new.payload - 'code';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists scrub_whatsapp_outbox_secret_payload on public.whatsapp_outbox;
create trigger scrub_whatsapp_outbox_secret_payload
  before update on public.whatsapp_outbox
  for each row
  execute function public.scrub_whatsapp_outbox_secret_payload();

-- ── 3. Guard trigger on whatsapp_event_templates ─────────────────────────────────────────────
create or replace function public.guard_secret_ref_type_template_mapping()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_covered boolean;
begin
  select redaction_covered into v_covered
  from public.whatsapp_payload_secret_ref_types
  where ref_type = new.event_key;

  if v_covered is distinct from null and v_covered is distinct from true then
    raise exception 'guard_secret_ref_type_template_mapping: event_key % carries a secret payload with no confirmed DB-level redaction coverage -- see whatsapp_payload_secret_ref_types', new.event_key;
  end if;

  return new;
end;
$$;

drop trigger if exists guard_secret_ref_type_template_mapping on public.whatsapp_event_templates;
create trigger guard_secret_ref_type_template_mapping
  before insert or update on public.whatsapp_event_templates
  for each row
  execute function public.guard_secret_ref_type_template_mapping();

revoke all on function public.scrub_whatsapp_outbox_secret_payload() from public, anon, authenticated;
revoke all on function public.guard_secret_ref_type_template_mapping() from public, anon, authenticated;
$migration$;
  v_embedded_test text := $testbody$-- Rolled-back test for 20261120100200_whatsapp_outbox_secret_payload_scrub.sql. The runner
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
$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;
  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded test text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  -- 4. LIVE-DEFINITION PRE-CHECKS
  if to_regclass('public.whatsapp_outbox') is null or to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'APPLY_REFUSED: whatsapp_outbox / whatsapp_event_templates do not both exist -- this migration depends on 20261016300000';
  end if;
  if to_regclass('public.whatsapp_payload_secret_ref_types') is not null then
    raise exception 'APPLY_REFUSED: public.whatsapp_payload_secret_ref_types already exists before this migration ran';
  end if;
  if to_regprocedure('public.scrub_whatsapp_outbox_secret_payload()') is not null then
    raise exception 'APPLY_REFUSED: public.scrub_whatsapp_outbox_secret_payload() already exists before this migration ran';
  end if;
  if to_regprocedure('public.guard_secret_ref_type_template_mapping()') is not null then
    raise exception 'APPLY_REFUSED: public.guard_secret_ref_type_template_mapping() already exists before this migration ran';
  end if;

  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\_\_TEST\_%' escape '\'
  ) r;

  -- 4. RUN -- apply the pinned migration verbatim (create-or-replace / create table if not
  -- exists / create trigger after an explicit drop, idempotent), then the test.
  execute replace(v_embedded_migration, E'\r', '');

  begin
    execute replace(v_embedded_test, E'\r', '');
  exception when others then
    v_inner_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\_\_TEST\_%' escape '\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\_\_TEST\_%' escape '\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', both embedded-text sha256 hashes verified'
    || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\nok   migration applied inside this still-open transaction (create-or-replace / create-if-not-exists, idempotent)'
    || E'\n--- embedded test output ---' || E'\n' || coalesce(v_inner_result, '(test raised no exception -- unexpected)') || E'\n--- end embedded test output ---'
    || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox/whatsapp_event_templates rows CHANGED -- this rehearsal mutated real data'
         else 'ok   real whatsapp_outbox/whatsapp_event_templates rows unchanged -- this rehearsal mutated no real data' end;

  raise exception E'RESULTS:\n%', res;
end
$rehearsal$;
