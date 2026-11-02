// One-off generator for the whatsapp_outbox secret-payload-scrub migration's rehearsal/apply/
// dryrun scripts, modeled on gen_fast_dispatch_scripts.mjs's own convention. Not part of the app
// build.
import fs from "node:fs"
import crypto from "node:crypto"

function sha256(text) {
  return crypto.createHash("sha256").update(text.replace(/\r/g, ""), "utf8").digest("hex")
}
function readLF(p) {
  return fs.readFileSync(p, "utf8").replace(/\r/g, "")
}

const MIGRATION_PATH = "supabase/migrations/20261120100200_whatsapp_outbox_secret_payload_scrub.sql"
const TEST_PATH = "supabase/tests/whatsapp_outbox_secret_payload_scrub.test.sql"
const migrationText = readLF(MIGRATION_PATH)
const testText = readLF(TEST_PATH)
const migrationHash = sha256(migrationText)
const testHash = sha256(testText)
console.log("migration sha256:", migrationHash)
console.log("test sha256:", testHash)

const ORG_FP = "6f891cf85011f08c2f22fb4a208d21bd"
const VERSION = "20261120100200"

const PRECHECKS = `
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
  end if;`

const POSTCHECKS = `
  -- 9. POST-APPLY CHECKS
  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- whatsapp_payload_secret_ref_types does not exist';
  end if;
  if to_regprocedure('public.scrub_whatsapp_outbox_secret_payload()') is null
     or to_regprocedure('public.guard_secret_ref_type_template_mapping()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two new trigger functions does not exist';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'scrub_whatsapp_outbox_secret_payload' and tgrelid = 'public.whatsapp_outbox'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub_whatsapp_outbox_secret_payload trigger is not attached to whatsapp_outbox';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'guard_secret_ref_type_template_mapping' and tgrelid = 'public.whatsapp_event_templates'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard_secret_ref_type_template_mapping trigger is not attached to whatsapp_event_templates';
  end if;
  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_link_otp registry row missing or not marked covered';
  end if;
  if has_function_privilege('anon', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     or has_function_privilege('anon', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two new functions is anon/authenticated-executable';
  end if;
  if exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- a customer_link_otp whatsapp_event_templates row exists; this migration must never wire one';
  end if;`

function rehearsalSql() {
  return `-- Rehearsal wrapper for ${MIGRATION_PATH} + ${TEST_PATH}.
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
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash text := '${migrationHash}';
  v_expected_test_hash      text := '${testHash}';
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before           text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_migration   text := $migration$${migrationText}$migration$;
  v_embedded_test text := $testbody$${testText}$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\\_\\_TEST%' escape '\\'
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
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;
  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded test text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;
${PRECHECKS}

  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  -- 4. RUN -- apply the pinned migration verbatim (create-or-replace / create table if not
  -- exists / create trigger after an explicit drop, idempotent), then the test.
  execute replace(v_embedded_migration, E'\\r', '');

  begin
    execute replace(v_embedded_test, E'\\r', '');
  exception when others then
    v_inner_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', both embedded-text sha256 hashes verified'
    || E'\\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\\nok   migration applied inside this still-open transaction (create-or-replace / create-if-not-exists, idempotent)'
    || E'\\n--- embedded test output ---' || E'\\n' || coalesce(v_inner_result, '(test raised no exception -- unexpected)') || E'\\n--- end embedded test output ---'
    || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox/whatsapp_event_templates rows CHANGED -- this rehearsal mutated real data'
         else 'ok   real whatsapp_outbox/whatsapp_event_templates rows unchanged -- this rehearsal mutated no real data' end;

  raise exception E'RESULTS:\\n%', res;
end
$rehearsal$;
`
}

function applySql({ dryrun }) {
  const dryrunRaise = dryrun
    ? `  -- DRYRUN-OK: literal first statement of the outer DO block's body -- a pure syntax/compile
  -- check of this exact file. The deeper proof comes from the separate rehearsal wrapper.
  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';

`
    : ""
  return `-- ${dryrun ? "DRYRUN-OK copy of the " : ""}GO APPLY script for migration ${VERSION}_whatsapp_outbox_secret_payload_scrub.sql
-- (closes the HIGH finding from the fast-dispatch Edge Function review: whatsapp_outbox's
-- existing redaction-on-send/give-up logic never cleared template_params -- this migration adds a
-- DB-level scrub trigger that does, plus a guard trigger refusing to map any secret-carrying
-- ref_type to a template until its redaction coverage is confirmed in a new registry table),
-- branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
${dryrun
    ? "-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs."
    : "-- (standing hard rule: no DB access of any kind beyond the explicitly-allowed rehearsal). The\n-- owner runs this by hand, after 11:00 IST and after typing the exact word \"APPROVED\" for this\n-- specific migration, once satisfied the sha256-pinned migration text embedded below is\n-- byte-for-byte the reviewed migration file."}
--
-- Re-running this script after a successful apply is always a safe no-op refusal (step 3:
-- already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.wa_outbox_scrub_apply_status;
create temp table wa_outbox_scrub_apply_status (
  migration_version text,
  version_registered boolean,
  registry_exists boolean,
  triggers_attached boolean,
  functions_not_anon_executable boolean,
  no_template_mapping boolean,
  newly_leaked_functions text[],
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '${migrationHash}';
  v_actual_migration_hash    text;
  v_migration_version        text := '${VERSION}';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
  v_embedded_migration       text := $migration$${migrationText}$migration$;
begin
${dryrunRaise}  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\\_\\_TEST%' escape '\\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)',
      v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  -- 1. LOCK: scoped to this transaction only.
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST.
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  select exists(
    select 1 from supabase_migrations.schema_migrations where version = v_migration_version
  ) into v_already_registered;

  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered -- stop, nothing applied', v_migration_version;
  end if;
${PRECHECKS}

  -- 5. LEAK SNAPSHOT (BEFORE)
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_before
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  -- 6. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'whatsapp_outbox_secret_payload_scrub', array[replace(v_embedded_migration, E'\\r', '')]);
${POSTCHECKS}

  -- 9x. DIFF-BASED leak check -- only NEW anon/PUBLIC-executable functions fail this.
  select coalesce(array_agg(sig order by sig), array[]::text[]) into v_leaked_after
  from (
    select distinct (p.oid::regprocedure)::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where n.nspname = 'public'
      and a.privilege_type = 'EXECUTE'
      and (a.grantee = 0 or a.grantee = (select oid from pg_roles where rolname = 'anon'))
  ) s;

  select coalesce(array_agg(x order by x), array[]::text[]) into v_newly_leaked
  from (select unnest(v_leaked_after) as x except select unnest(v_leaked_before)) d;

  if array_length(v_newly_leaked, 1) is not null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed % function(s) to PUBLIC/anon that were not executable before it ran: %',
      array_length(v_newly_leaked, 1), v_newly_leaked;
  end if;

  -- 9y. real-organisation fingerprint unchanged.
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\\_\\_TEST%' escape '\\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.wa_outbox_scrub_apply_status (migration_version, version_registered, registry_exists, triggers_attached, functions_not_anon_executable, no_template_mapping, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regclass('public.whatsapp_payload_secret_ref_types') is not null),
    (exists (select 1 from pg_trigger where tgname = 'scrub_whatsapp_outbox_secret_payload' and tgrelid = 'public.whatsapp_outbox'::regclass and not tgisinternal)
     and exists (select 1 from pg_trigger where tgname = 'guard_secret_ref_type_template_mapping' and tgrelid = 'public.whatsapp_event_templates'::regclass and not tgisinternal)),
    (not has_function_privilege('anon', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE') and not has_function_privilege('authenticated', 'public.scrub_whatsapp_outbox_secret_payload()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE') and not has_function_privilege('authenticated', 'public.guard_secret_ref_type_template_mapping()', 'EXECUTE')),
    (not exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.wa_outbox_scrub_apply_status;
`
}

fs.writeFileSync("supabase/ops/whatsapp_outbox_secret_payload_scrub.rehearsal.sql", rehearsalSql())
console.log("wrote rehearsal.sql")
fs.writeFileSync("supabase/ops/20261120100200_whatsapp_outbox_secret_payload_scrub.apply.sql", applySql({ dryrun: false }))
console.log("wrote apply.sql")
fs.writeFileSync("supabase/ops/20261120100200_whatsapp_outbox_secret_payload_scrub.apply.dryrun.sql", applySql({ dryrun: true }))
console.log("wrote apply.dryrun.sql")
console.log("DONE")
