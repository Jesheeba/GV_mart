// Generator for 20261121100200_customer_link_otp_template_mapping.sql's apply/dryrun scripts, and
// a COMBINED rehearsal that chains the full reconciled package in one transaction: the prereq
// (20261120100200, committed by a concurrent session, not yet live), the dispatch-hardening
// migration (20261121100100) + its test, then THIS mapping migration + its test. Modeled on
// gen_dispatch_hardening_scripts.mjs's own convention.
import fs from "node:fs"
import crypto from "node:crypto"

function sha256(text) {
  return crypto.createHash("sha256").update(text.replace(/\r/g, ""), "utf8").digest("hex")
}
function readLF(p) {
  return fs.readFileSync(p, "utf8").replace(/\r/g, "")
}

const PREREQ_PATH = "supabase/migrations/20261120100200_whatsapp_outbox_secret_payload_scrub.sql"
const HARDENING_PATH = "supabase/migrations/20261121100100_customer_link_otp_dispatch_hardening.sql"
const HARDENING_TEST_PATH = "supabase/tests/customer_link_otp_dispatch_hardening.test.sql"
const MAPPING_PATH = "supabase/migrations/20261121100200_customer_link_otp_template_mapping.sql"
const MAPPING_TEST_PATH = "supabase/tests/customer_link_otp_template_mapping.test.sql"

const prereqText = readLF(PREREQ_PATH)
const hardeningText = readLF(HARDENING_PATH)
const hardeningTestText = readLF(HARDENING_TEST_PATH)
const mappingText = readLF(MAPPING_PATH)
const mappingTestText = readLF(MAPPING_TEST_PATH)

const prereqHash = sha256(prereqText)
const hardeningHash = sha256(hardeningText)
const hardeningTestHash = sha256(hardeningTestText)
const mappingHash = sha256(mappingText)
const mappingTestHash = sha256(mappingTestText)

console.log("prereq (20261120100200) sha256:", prereqHash)
console.log("hardening (20261121100100) sha256:", hardeningHash)
console.log("hardening test sha256:", hardeningTestHash)
console.log("mapping (20261121100200) sha256:", mappingHash)
console.log("mapping test sha256:", mappingTestHash)

const ORG_FP = "6f891cf85011f08c2f22fb4a208d21bd"
const MAPPING_VERSION = "20261121100200"

function combinedRehearsalSql() {
  return `-- COMBINED rehearsal: the full reconciled customer_link_otp redaction + template-mapping
-- package in ONE transaction -- 20261120100200 (prereq, committed by a concurrent session, not
-- yet live) -> 20261121100100 (dispatch hardening) + its test -> 20261121100200 (template mapping)
-- + its test. WRITTEN ONLY -- never executed against any database by the agent that produced this
-- file except through the sha256-verified supabase/ops/run_rehearsal.mjs, and only as a REHEARSAL:
-- this block always ends in RAISE EXCEPTION, so nothing it does can ever commit.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_actual_org_fingerprint   text;
  v_expected_prereq_hash        text := '${prereqHash}';
  v_expected_hardening_hash     text := '${hardeningHash}';
  v_expected_hardening_test_hash text := '${hardeningTestHash}';
  v_expected_mapping_hash       text := '${mappingHash}';
  v_expected_mapping_test_hash  text := '${mappingTestHash}';
  v_actual_hash text;
  v_fp_before text;
  v_fp_after text;
  v_hardening_test_result text;
  v_mapping_test_result text;
  res text := '';
  v_embedded_prereq        text := $prereq$${prereqText}$prereq$;
  v_embedded_hardening      text := $hardening$${hardeningText}$hardening$;
  v_embedded_hardening_test text := $hardeningtest$${hardeningTestText}$hardeningtest$;
  v_embedded_mapping         text := $mapping$${mappingText}$mapping$;
  v_embedded_mapping_test    text := $mappingtest$${mappingTestText}$mappingtest$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\\_\\_TEST%' escape '\\'
  order by o.created_at asc
  limit 1;
  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  -- 2. GATE -- 11:00 IST
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN -- all five embedded texts must match their pinned sha256.
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_prereq, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_prereq_hash then raise exception 'REHEARSAL_REFUSED: prereq hash mismatch (expected %, got %)', v_expected_prereq_hash, v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_hardening_hash then raise exception 'REHEARSAL_REFUSED: hardening migration hash mismatch (expected %, got %)', v_expected_hardening_hash, v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_hardening_test_hash then raise exception 'REHEARSAL_REFUSED: hardening test hash mismatch (expected %, got %)', v_expected_hardening_test_hash, v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_mapping_hash then raise exception 'REHEARSAL_REFUSED: mapping migration hash mismatch (expected %, got %)', v_expected_mapping_hash, v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from v_expected_mapping_test_hash then raise exception 'REHEARSAL_REFUSED: mapping test hash mismatch (expected %, got %)', v_expected_mapping_test_hash, v_actual_hash; end if;

  -- NOTE: this fingerprint deliberately EXCLUDES whatsapp_event_templates rows for
  -- event_key = 'customer_link_otp' -- the mapping migration (20261121100200) creating that row
  -- for every real org is its own INTENDED effect (the thing this migration exists to do), not an
  -- unintended mutation to catch. It is checked separately, explicitly, below (P2/P3) instead of
  -- being folded into a fingerprint that would always "fail" on the migration's own correct work.
  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\\_\\_TEST\\_%' escape '\\' and t.event_key <> 'customer_link_otp'
  ) r;

  -- 4. RUN, in order: prereq -> hardening -> hardening test -> mapping -> mapping test.
  execute replace(v_embedded_prereq, E'\\r', '');
  execute replace(v_embedded_hardening, E'\\r', '');
  begin
    execute replace(v_embedded_hardening_test, E'\\r', '');
  exception when others then
    v_hardening_test_result := sqlerrm;
  end;
  execute replace(v_embedded_mapping, E'\\r', '');
  begin
    execute replace(v_embedded_mapping_test, E'\\r', '');
  exception when others then
    v_mapping_test_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\\_\\_TEST\\_%' escape '\\' and t.event_key <> 'customer_link_otp'
  ) r;

  -- Explicit, separate check of the mapping migration's OWN intended effect: a real org's
  -- customer_link_otp -> lexdraft_otp row now exists with the right shape.
  declare
    v_real_mapping_ok boolean;
  begin
    select exists (
      select 1 from public.whatsapp_event_templates t
      join public.organizations o on o.id = t.org_id
      where t.event_key = 'customer_link_otp' and t.wasi_template_name = 'lexdraft_otp'
        and t.has_auth_copy_code_button = true and t.param_map = '{"1": "code"}'::jsonb
        and o.name not like '\\_\\_TEST%' escape '\\'
    ) into v_real_mapping_ok;

    res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', all five embedded-text sha256 hashes verified'
      || E'\\nINFO real-row fingerprint BEFORE (outbox + non-customer_link_otp templates) = ' || v_fp_before
      || E'\\nok   prereq + hardening + mapping applied inside this still-open transaction'
      || E'\\n--- hardening test output ---' || E'\\n' || coalesce(v_hardening_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end hardening test output ---'
      || E'\\n--- mapping test output ---' || E'\\n' || coalesce(v_mapping_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end mapping test output ---'
      || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after
      || E'\\n' || case when v_fp_after is distinct from v_fp_before
           then 'FAIL real whatsapp_outbox/other-template rows CHANGED -- this rehearsal mutated unrelated real data'
           else 'ok   real whatsapp_outbox rows and every OTHER template mapping unchanged -- this rehearsal mutated no unrelated real data' end
      || E'\\n' || case when v_real_mapping_ok then 'ok   the mapping migration''s own intended effect (a real org''s customer_link_otp -> lexdraft_otp row) is correctly shaped' else 'FAIL the mapping migration''s own intended effect is missing or wrong' end;
  end;

  raise exception E'RESULTS:\\n%', res;
end
$rehearsal$;
`
}

function mappingApplySql({ dryrun }) {
  const dryrunRaise = dryrun
    ? `  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';\n\n`
    : ""
  return `-- ${dryrun ? "DRYRUN-OK copy of the " : ""}GO APPLY script for migration ${MAPPING_VERSION}_customer_link_otp_template_mapping.sql
-- (the customer_link_otp -> lexdraft_otp mapping, LAST in this feature's ordering, after the
-- redaction-hardening migration), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
${dryrun
    ? "-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs."
    : "-- (standing hard rule). The owner runs this by hand, after 11:00 IST and after typing the exact\n-- word \"APPROVED\" for this specific migration, once satisfied the sha256-pinned migration text\n-- embedded below is byte-for-byte the reviewed migration file, AND after confirming\n-- 20261121100100 is already applied live (this script's own precheck, step 4, refuses to run\n-- otherwise)."}

drop table if exists pg_temp.template_mapping_apply_status;
create temp table template_mapping_apply_status (
  migration_version text,
  version_registered boolean,
  column_exists boolean,
  mapping_row_correct boolean,
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '${mappingHash}';
  v_actual_migration_hash    text;
  v_migration_version        text := '${MAPPING_VERSION}';
  v_already_registered       boolean;
  v_embedded_migration       text := $migration$${mappingText}$migration$;
begin
${dryrunRaise}  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1;
  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'APPLY_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'APPLY_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  select exists(select 1 from supabase_migrations.schema_migrations where version = v_migration_version) into v_already_registered;
  if v_already_registered then
    raise exception 'APPLY_REFUSED: migration % is already registered -- stop, nothing applied', v_migration_version;
  end if;

  -- precondition: the hardening migration must already be live.
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    raise exception 'APPLY_REFUSED: prerequisite migration 20261121100100_customer_link_otp_dispatch_hardening.sql is not applied live yet';
  end if;
  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'APPLY_REFUSED: customer_link_otp is not registered as redaction_covered';
  end if;
  if exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp' and wasi_template_name = 'lexdraft_otp') then
    raise exception 'APPLY_REFUSED: a customer_link_otp -> lexdraft_otp mapping row already exists before this migration ran';
  end if;

  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_migration_hash;
  end if;

  execute replace(v_embedded_migration, E'\\r', '');

  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_link_otp_template_mapping', array[replace(v_embedded_migration, E'\\r', '')]);

  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'whatsapp_event_templates' and column_name = 'has_auth_copy_code_button') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- has_auth_copy_code_button column missing';
  end if;
  if not exists (select 1 from public.whatsapp_event_templates where event_key = 'customer_link_otp' and wasi_template_name = 'lexdraft_otp' and has_auth_copy_code_button = true) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- mapping row missing or wrong';
  end if;

  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1;
  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)', v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  insert into pg_temp.template_mapping_apply_status (migration_version, version_registered, column_exists, mapping_row_correct, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (v_migration_version, true, true, true, v_org_fingerprint_before, v_org_fingerprint_after, now());
end
$apply$;

select * from pg_temp.template_mapping_apply_status;
`
}

fs.writeFileSync("supabase/ops/customer_link_otp_phase3_combined.rehearsal.sql", combinedRehearsalSql())
console.log("wrote combined rehearsal.sql")
fs.writeFileSync("supabase/ops/20261121100200_customer_link_otp_template_mapping.apply.sql", mappingApplySql({ dryrun: false }))
console.log("wrote mapping apply.sql")
fs.writeFileSync("supabase/ops/20261121100200_customer_link_otp_template_mapping.apply.dryrun.sql", mappingApplySql({ dryrun: true }))
console.log("wrote mapping apply.dryrun.sql")
console.log("DONE")
