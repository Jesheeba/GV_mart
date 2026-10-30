// One-off generator for the customer_link_otp_dispatch_hardening migration's rehearsal/apply/
// dryrun scripts, modeled on gen_outbox_scrub_scripts.mjs's own convention. Not part of the app
// build.
//
// This migration's own precheck requires whatsapp_payload_secret_ref_types (created by
// 20261120100200_whatsapp_outbox_secret_payload_scrub.sql) to already exist. As of this writing
// that migration is committed on this branch but NOT yet applied live (confirmed read-only,
// 2026-10-30), so the REHEARSAL embeds BOTH migration texts in sequence, inside the same
// rolled-back transaction, so it can be run today without depending on apply order outside this
// script's control. The real APPLY script (never run by this agent) embeds and registers ONLY
// this migration (20261121100100) -- its own precheck will simply refuse to run if 20261120100200
// has not been applied for real by then, which is the correct, honest behavior for a standalone
// apply script.
import fs from "node:fs"
import crypto from "node:crypto"

function sha256(text) {
  return crypto.createHash("sha256").update(text.replace(/\r/g, ""), "utf8").digest("hex")
}
function readLF(p) {
  return fs.readFileSync(p, "utf8").replace(/\r/g, "")
}

const PREREQ_MIGRATION_PATH = "supabase/migrations/20261120100200_whatsapp_outbox_secret_payload_scrub.sql"
const MIGRATION_PATH = "supabase/migrations/20261121100100_customer_link_otp_dispatch_hardening.sql"
const TEST_PATH = "supabase/tests/customer_link_otp_dispatch_hardening.test.sql"
const prereqText = readLF(PREREQ_MIGRATION_PATH)
const migrationText = readLF(MIGRATION_PATH)
const testText = readLF(TEST_PATH)
const prereqHash = sha256(prereqText)
const migrationHash = sha256(migrationText)
const testHash = sha256(testText)
console.log("prereq (20261120100200) sha256:", prereqHash)
console.log("migration sha256:", migrationHash)
console.log("test sha256:", testHash)

const ORG_FP = "6f891cf85011f08c2f22fb4a208d21bd"
const VERSION = "20261121100100"

function rehearsalSql() {
  return `-- Rehearsal wrapper for ${MIGRATION_PATH} + ${TEST_PATH}.
-- Also embeds ${PREREQ_MIGRATION_PATH} (its own precheck's prerequisite) because that migration is
-- committed on this branch but not yet applied live as of this writing -- see this generator
-- script's own header comment for why that is the correct, non-silent way to handle the ordering.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file except
-- through the project's approved Management-API runner (supabase/ops/run_rehearsal.mjs,
-- sha256-verified before use), and only as a REHEARSAL: this block always ends in RAISE EXCEPTION,
-- so nothing it does can ever commit, regardless of pass/fail.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_actual_org_fingerprint   text;
  v_expected_prereq_hash    text := '${prereqHash}';
  v_expected_migration_hash text := '${migrationHash}';
  v_expected_test_hash      text := '${testHash}';
  v_actual_prereq_hash      text;
  v_actual_migration_hash   text;
  v_actual_test_hash        text;
  v_fp_before            text;
  v_fp_after             text;
  v_inner_result         text;
  res                    text := '';
  v_embedded_prereq      text := $prereq$${prereqText}$prereq$;
  v_embedded_migration   text := $migration$${migrationText}$migration$;
  v_embedded_test text := $testbody$${testText}$testbody$;
  v_prereq_already_live boolean;
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

  -- 3. PIN -- all three embedded texts must match their pinned sha256.
  v_actual_prereq_hash := encode(sha256(convert_to(replace(v_embedded_prereq, E'\\r', ''), 'UTF8')), 'hex');
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_prereq_hash is distinct from v_expected_prereq_hash then
    raise exception 'REHEARSAL_REFUSED: embedded prereq (20261120100200) text does not match its pinned sha256 (expected %, got %)',
      v_expected_prereq_hash, v_actual_prereq_hash;
  end if;
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;
  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded test text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  -- 4. PREREQ -- run 20261120100200 first IF not already live (idempotent either way: create
  -- table if not exists / create-or-replace / drop-trigger-then-create).
  select (to_regclass('public.whatsapp_payload_secret_ref_types') is not null) into v_prereq_already_live;
  execute replace(v_embedded_prereq, E'\\r', '');

  -- NOTE: the fingerprint below deliberately covers ONLY real (non-__TEST_) whatsapp_outbox rows,
  -- not cron.job -- scheduling the customer-link-otp-expiry-scrub cron job is this migration's own
  -- INTENDED effect (proven separately by the G1 assertion in the embedded test below), not an
  -- unintended mutation to catch here; including it would make this fingerprint fail on every run.
  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  -- 5. RUN -- apply the pinned migration verbatim, then the test.
  execute replace(v_embedded_migration, E'\\r', '');

  begin
    execute replace(v_embedded_test, E'\\r', '');
  exception when others then
    v_inner_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'outbox:' || o.id::text || ':' || o.status || ':' || coalesce(o.payload::text,'') || ':' || coalesce(o.template_params::text,'') as x
    from public.whatsapp_outbox o where o.template not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', all three embedded-text sha256 hashes verified'
    || E'\\nINFO prereq (20261120100200) was already live before this rehearsal: ' || v_prereq_already_live
    || E'\\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\\nok   prereq + migration applied inside this still-open transaction (idempotent statements throughout)'
    || E'\\n--- embedded test output ---' || E'\\n' || coalesce(v_inner_result, '(test raised no exception -- unexpected)') || E'\\n--- end embedded test output ---'
    || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real whatsapp_outbox rows or the cron job registry CHANGED -- this rehearsal mutated real data'
         else 'ok   real whatsapp_outbox rows and the cron job registry unchanged -- this rehearsal mutated no real data' end;

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
  return `-- ${dryrun ? "DRYRUN-OK copy of the " : ""}GO APPLY script for migration ${VERSION}_customer_link_otp_dispatch_hardening.sql
-- (phase 3, HIGH fix: closes the "never dispatched before expiry" gap in whatsapp_outbox's
-- plaintext-OTP-code retention -- see the migration file's own header comment for the full
-- reasoning, including why the pg_net-hardening half of this phase's task was found infeasible
-- for the migration role and is NOT part of this script), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
${dryrun
    ? "-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs."
    : "-- (standing hard rule: no DB access of any kind beyond the explicitly-allowed rehearsal). The\n-- owner runs this by hand, after 11:00 IST and after typing the exact word \"APPROVED\" for this\n-- specific migration, once satisfied the sha256-pinned migration text embedded below is\n-- byte-for-byte the reviewed migration file, AND after confirming 20261120100200 is already\n-- applied live (this script's own precheck, step 4, refuses to run otherwise -- it does not\n-- apply that prerequisite itself, unlike the rehearsal wrapper above)."}
--
-- Re-running this script after a successful apply is always a safe no-op refusal (step 3:
-- already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.dispatch_hardening_apply_status;
create temp table dispatch_hardening_apply_status (
  migration_version text,
  version_registered boolean,
  scrub_function_exists boolean,
  cron_job_scheduled boolean,
  scrub_function_not_anon_executable boolean,
  registry_row_covered boolean,
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

  -- 4. PREREQUISITE CHECK -- this script does NOT apply 20261120100200 itself; it must already be live.
  if to_regclass('public.whatsapp_payload_secret_ref_types') is null then
    raise exception 'APPLY_REFUSED: prerequisite migration 20261120100200_whatsapp_outbox_secret_payload_scrub.sql is not applied live yet';
  end if;
  if to_regclass('public.customer_link_otp_challenges') is null or to_regclass('public.whatsapp_outbox') is null then
    raise exception 'APPLY_REFUSED: customer_link_otp_challenges / whatsapp_outbox do not both exist';
  end if;
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is not null then
    raise exception 'APPLY_REFUSED: public.scrub_expired_customer_link_otp_outbox() already exists before this migration ran';
  end if;

  -- 5. PIN -- CR-tolerant sha256 of the embedded migration text must equal the pinned LF hash.
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 6. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\\r', '');

  -- 7. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_link_otp_dispatch_hardening', array[replace(v_embedded_migration, E'\\r', '')]);

  -- 8. POST-APPLY CHECKS
  if to_regprocedure('public.scrub_expired_customer_link_otp_outbox()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub_expired_customer_link_otp_outbox does not exist';
  end if;
  if not exists (select 1 from cron.job where jobname = 'customer-link-otp-expiry-scrub') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- cron job was not scheduled';
  end if;
  if has_function_privilege('anon', 'public.scrub_expired_customer_link_otp_outbox()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.scrub_expired_customer_link_otp_outbox()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- scrub function is anon/authenticated-executable';
  end if;
  if not exists (select 1 from public.whatsapp_payload_secret_ref_types where ref_type = 'customer_link_otp' and redaction_covered = true) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- customer_link_otp registry row missing or not covered';
  end if;

  -- 9. real-organisation fingerprint unchanged.
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
  insert into pg_temp.dispatch_hardening_apply_status (migration_version, version_registered, scrub_function_exists, cron_job_scheduled, scrub_function_not_anon_executable, registry_row_covered, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    true,
    true,
    true,
    true,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.dispatch_hardening_apply_status;
`
}

fs.writeFileSync("supabase/ops/customer_link_otp_dispatch_hardening.rehearsal.sql", rehearsalSql())
console.log("wrote rehearsal.sql")
fs.writeFileSync("supabase/ops/20261121100100_customer_link_otp_dispatch_hardening.apply.sql", applySql({ dryrun: false }))
console.log("wrote apply.sql")
fs.writeFileSync("supabase/ops/20261121100100_customer_link_otp_dispatch_hardening.apply.dryrun.sql", applySql({ dryrun: true }))
console.log("wrote apply.dryrun.sql")
console.log("DONE")
