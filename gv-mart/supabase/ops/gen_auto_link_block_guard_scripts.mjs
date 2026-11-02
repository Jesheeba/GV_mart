// Generator for 20261121100150_customer_link_otp_respects_auto_link_block.sql's apply/dryrun
// scripts, and a FULL combined rehearsal chaining the entire reconciled package in order:
// 20261120100200 (prereq, redaction trigger) -> 20261121100100 (dispatch hardening) + test ->
// 20261121100150 (THIS migration, the auto_link_blocked_at guard) + test ->
// 20261121100200 (template mapping) + test. Modeled on gen_template_mapping_scripts.mjs.
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
const GUARD_PATH = "supabase/migrations/20261121100150_customer_link_otp_respects_auto_link_block.sql"
const GUARD_TEST_PATH = "supabase/tests/customer_link_otp_respects_auto_link_block.test.sql"
const MAPPING_PATH = "supabase/migrations/20261121100200_customer_link_otp_template_mapping.sql"
const MAPPING_TEST_PATH = "supabase/tests/customer_link_otp_template_mapping.test.sql"

const texts = {
  prereq: readLF(PREREQ_PATH),
  hardening: readLF(HARDENING_PATH),
  hardeningTest: readLF(HARDENING_TEST_PATH),
  guard: readLF(GUARD_PATH),
  guardTest: readLF(GUARD_TEST_PATH),
  mapping: readLF(MAPPING_PATH),
  mappingTest: readLF(MAPPING_TEST_PATH),
}
const hashes = Object.fromEntries(Object.entries(texts).map(([k, v]) => [k, sha256(v)]))
for (const [k, h] of Object.entries(hashes)) console.log(`${k} sha256:`, h)

const ORG_FP = "6f891cf85011f08c2f22fb4a208d21bd"
const GUARD_VERSION = "20261121100150"

function combinedRehearsalSql() {
  return `-- COMBINED rehearsal: the FULL reconciled customer_link_otp package, in ONE transaction --
-- 20261120100200 (prereq) -> 20261121100100 (dispatch hardening) + test ->
-- 20261121100150 (auto_link_blocked_at guard, THIS round) + test ->
-- 20261121100200 (template mapping) + test. WRITTEN ONLY -- never executed against any database
-- by the agent that produced this file except through the sha256-verified
-- supabase/ops/run_rehearsal.mjs, and only as a REHEARSAL: ends in RAISE EXCEPTION, nothing commits.
do $rehearsal$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_actual_org_fingerprint text;
  v_actual_hash text;
  v_fp_before text;
  v_fp_after text;
  v_hardening_test_result text;
  v_guard_test_result text;
  v_mapping_test_result text;
  res text := '';
  v_embedded_prereq text := $prereq$${texts.prereq}$prereq$;
  v_embedded_hardening text := $hardening$${texts.hardening}$hardening$;
  v_embedded_hardening_test text := $hardeningtest$${texts.hardeningTest}$hardeningtest$;
  v_embedded_guard text := $guard$${texts.guard}$guard$;
  v_embedded_guard_test text := $guardtest$${texts.guardTest}$guardtest$;
  v_embedded_mapping text := $mapping$${texts.mapping}$mapping$;
  v_embedded_mapping_test text := $mappingtest$${texts.mappingTest}$mappingtest$;
begin
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1;
  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch (expected %, got %)', v_expected_org_fingerprint, v_actual_org_fingerprint;
  end if;

  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this script only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_prereq, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.prereq}' then raise exception 'REHEARSAL_REFUSED: prereq hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.hardening}' then raise exception 'REHEARSAL_REFUSED: hardening hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_hardening_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.hardeningTest}' then raise exception 'REHEARSAL_REFUSED: hardening test hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_guard, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.guard}' then raise exception 'REHEARSAL_REFUSED: guard migration hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_guard_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.guardTest}' then raise exception 'REHEARSAL_REFUSED: guard test hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.mapping}' then raise exception 'REHEARSAL_REFUSED: mapping migration hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mapping_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.mappingTest}' then raise exception 'REHEARSAL_REFUSED: mapping test hash mismatch (got %)', v_actual_hash; end if;

  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
    union all
    select 'tmpl:' || t.id::text || ':' || t.event_key || ':' || t.wasi_template_name from public.whatsapp_event_templates t
    where t.wasi_template_name not like '\\_\\_TEST\\_%' escape '\\' and t.event_key <> 'customer_link_otp'
    union all
    select 'cust_link:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'')
    from public.customers c where c.name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  -- RUN, in order: prereq -> hardening -> hardening test -> guard -> guard test -> mapping -> mapping test.
  execute replace(v_embedded_prereq, E'\\r', '');
  execute replace(v_embedded_hardening, E'\\r', '');
  begin
    execute replace(v_embedded_hardening_test, E'\\r', '');
  exception when others then
    v_hardening_test_result := sqlerrm;
  end;
  execute replace(v_embedded_guard, E'\\r', '');
  begin
    execute replace(v_embedded_guard_test, E'\\r', '');
  exception when others then
    v_guard_test_result := sqlerrm;
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
    union all
    select 'cust_link:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'')
    from public.customers c where c.name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', all seven embedded-text sha256 hashes verified'
    || E'\\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\\nok   prereq + hardening + guard + mapping applied inside this still-open transaction'
    || E'\\n--- hardening test output ---' || E'\\n' || coalesce(v_hardening_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end hardening test output ---'
    || E'\\n--- guard test output ---' || E'\\n' || coalesce(v_guard_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end guard test output ---'
    || E'\\n--- mapping test output ---' || E'\\n' || coalesce(v_mapping_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end mapping test output ---'
    || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox/other-template/real-customer link rows CHANGED -- this rehearsal mutated unrelated real data'
         else 'ok   real whatsapp_outbox rows, every OTHER template mapping, and every REAL customer''s own link/block state unchanged -- this rehearsal mutated no unrelated real data' end;

  raise exception E'RESULTS:\\n%', res;
end
$rehearsal$;
`
}

function guardApplySql({ dryrun }) {
  const dryrunRaise = dryrun
    ? `  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';\n\n`
    : ""
  return `-- ${dryrun ? "DRYRUN-OK copy of the " : ""}GO APPLY script for migration ${GUARD_VERSION}_customer_link_otp_respects_auto_link_block.sql
-- (owner-approved guard: verify_customer_link_code / request_customer_link_code now respect
-- customers.auto_link_blocked_at), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
${dryrun
    ? "-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs."
    : "-- (standing hard rule). The owner (or the coordinator, per this round's explicit instruction)\n-- runs this by hand, after 11:00 IST and after typing the exact word \"APPROVED\" for this\n-- specific migration, once satisfied the sha256-pinned migration text embedded below is\n-- byte-for-byte the reviewed migration file, AND after confirming 20261121100100 is already\n-- applied live (this script's own precheck, step 4, refuses to run otherwise). This script ALSO\n-- re-checks the LIVE bodies of request_customer_link_code/verify_customer_link_code against the\n-- same pinned hashes the migration text itself embeds -- if either drifted since this was\n-- written, this refuses, exactly like the migration's own DO block would."}

drop table if exists pg_temp.auto_link_block_guard_apply_status;
create temp table auto_link_block_guard_apply_status (
  migration_version text,
  version_registered boolean,
  functions_updated boolean,
  grants_unchanged boolean,
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

do $apply$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_org_fingerprint_before text;
  v_org_fingerprint_after text;
  v_expected_migration_hash text := '${hashes.guard}';
  v_actual_migration_hash text;
  v_migration_version text := '${GUARD_VERSION}';
  v_already_registered boolean;
  v_embedded_migration text := $migration$${texts.guard}$migration$;
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

  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    raise exception 'APPLY_REFUSED: prerequisite migration 20261121100100_customer_link_otp_dispatch_hardening.sql is not applied live yet';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='auto_link_blocked_at') then
    raise exception 'APPLY_REFUSED: customers.auto_link_blocked_at missing -- 20261130100000 not applied';
  end if;

  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)', v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- The migration's OWN DO block re-checks the live function bodies against its own pinned
  -- hashes and raises LIVE_DEFINITION_DRIFT if they no longer match -- that check runs as part
  -- of the execute below, not duplicated here.
  execute replace(v_embedded_migration, E'\\r', '');

  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_link_otp_respects_auto_link_block', array[replace(v_embedded_migration, E'\\r', '')]);

  if (select prosrc from pg_proc where oid = 'public.request_customer_link_code(text)'::regprocedure) not like '%v_match_auto_link_blocked_at%'
     or (select prosrc from pg_proc where oid = 'public.verify_customer_link_code(text)'::regprocedure) not like '%auto_link_blocked_at%' then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two functions does not contain the new check';
  end if;

  if has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.request_customer_link_code(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.verify_customer_link_code(text)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- grants changed (anon must stay no-execute, authenticated must keep execute)';
  end if;

  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1;
  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)', v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  insert into pg_temp.auto_link_block_guard_apply_status (migration_version, version_registered, functions_updated, grants_unchanged, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (v_migration_version, true, true, true, v_org_fingerprint_before, v_org_fingerprint_after, now());
end
$apply$;

select * from pg_temp.auto_link_block_guard_apply_status;
`
}

fs.writeFileSync("supabase/ops/customer_link_otp_phase3_combined.rehearsal.sql", combinedRehearsalSql())
console.log("wrote combined rehearsal.sql")
fs.writeFileSync("supabase/ops/20261121100150_customer_link_otp_respects_auto_link_block.apply.sql", guardApplySql({ dryrun: false }))
console.log("wrote guard apply.sql")
fs.writeFileSync("supabase/ops/20261121100150_customer_link_otp_respects_auto_link_block.apply.dryrun.sql", guardApplySql({ dryrun: true }))
console.log("wrote guard apply.dryrun.sql")
console.log("DONE")
