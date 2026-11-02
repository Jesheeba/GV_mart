// Generator for 20261130100100_customer_link_otp_merge_on_verify.sql's apply/dryrun scripts, and
// a FULL combined rehearsal chaining the entire reconciled package in order: 20261120100200
// (prereq) -> 20261121100100 (dispatch hardening) + test -> 20261121100150 (auto_link_blocked_at
// guard) + test -> 20261130100100 (THIS migration, merge-on-verify) + test -> 20261121100200
// (template mapping) + test. Modeled on gen_auto_link_block_guard_scripts.mjs.
import fs from "node:fs"
import crypto from "node:crypto"

function sha256(text) {
  return crypto.createHash("sha256").update(text.replace(/\r/g, ""), "utf8").digest("hex")
}
function readLF(p) {
  return fs.readFileSync(p, "utf8").replace(/\r/g, "")
}

// NOTE (2026-11-02): 20261120100200, 20261121100100, 20261121100150, and 20261121100200 are now
// ALL APPLIED LIVE for real (the coordinator ran the actual apply, independently verified clean).
// This generator therefore rehearses ONLY the one remaining pending migration, 20261130100100,
// against the REAL current live state -- embedding any of the four already-live migrations again
// here would make THEIR OWN internal drift checks fail (they each pin the hash of what was live
// BEFORE they themselves applied, not the current, post-themselves state) -- found by this
// generator's own earlier version actually failing exactly that way against the live project, not
// assumed.
const PATHS = {
  merge: "supabase/migrations/20261130100100_customer_link_otp_merge_on_verify.sql",
  mergeTest: "supabase/tests/customer_link_otp_merge_on_verify.test.sql",
}
const texts = Object.fromEntries(Object.entries(PATHS).map(([k, p]) => [k, readLF(p)]))
const hashes = Object.fromEntries(Object.entries(texts).map(([k, v]) => [k, sha256(v)]))
for (const [k, h] of Object.entries(hashes)) console.log(`${k} sha256:`, h)

const ORG_FP = "6f891cf85011f08c2f22fb4a208d21bd"
const MERGE_VERSION = "20261130100100"

function combinedRehearsalSql() {
  return `-- Rehearsal for 20261130100100_customer_link_otp_merge_on_verify.sql + its test, against the
-- REAL current live state (20261120100200/20261121100100/20261121100150/20261121100200 are all
-- already applied live for real as of this writing -- not re-embedded here; doing so would make
-- THEIR OWN internal drift checks fail, since each pins the hash of what was live BEFORE it
-- itself applied, not the current, post-itself state).
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file except
-- through the sha256-verified supabase/ops/run_rehearsal.mjs, and only as a REHEARSAL: ends in
-- RAISE EXCEPTION, so nothing it does can ever commit.
do $rehearsal$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_actual_org_fingerprint text;
  v_actual_hash text;
  v_fp_before text;
  v_fp_after text;
  v_merge_test_result text;
  res text := '';
  v_embedded_merge text := $merge$${texts.merge}$merge$;
  v_embedded_mergeTest text := $mergeTest$${texts.mergeTest}$mergeTest$;
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

  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_merge, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.merge}' then raise exception 'REHEARSAL_REFUSED: merge migration hash mismatch (got %)', v_actual_hash; end if;
  v_actual_hash := encode(sha256(convert_to(replace(v_embedded_mergeTest, E'\\r', ''), 'UTF8')), 'hex');
  if v_actual_hash is distinct from '${hashes.mergeTest}' then raise exception 'REHEARSAL_REFUSED: merge test hash mismatch (got %)', v_actual_hash; end if;

  -- Fingerprint deliberately covers every REAL (non-__TEST_) customer's own
  -- link/block/mobile/needs_review/archived state -- this migration's own job is to CHANGE
  -- exactly this for a throwaway __TEST_ customer, never a real one, so a real-row change here is
  -- a genuine failure, not an expected side effect.
  select md5(string_agg(x, ',' order by x)) into v_fp_before from (
    select 'cust:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'') || ':' || coalesce(c.mobile,'') || ':' || c.needs_review::text || ':' || coalesce(c.archived_at::text,'') as x
    from public.customers c where c.name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  execute replace(v_embedded_merge, E'\\r', '');
  begin
    execute replace(v_embedded_mergeTest, E'\\r', '');
  exception when others then
    v_merge_test_result := sqlerrm;
  end;

  select md5(string_agg(x, ',' order by x)) into v_fp_after from (
    select 'cust:' || c.id::text || ':' || coalesce(c.primary_profile_id::text,'') || ':' || coalesce(c.auto_link_blocked_at::text,'') || ':' || coalesce(c.mobile,'') || ':' || c.needs_review::text || ':' || coalesce(c.archived_at::text,'') as x
    from public.customers c where c.name not like '\\_\\_TEST\\_%' escape '\\'
  ) r;

  res := 'ok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || ', both embedded-text sha256 hashes verified'
    || E'\\nINFO real-row fingerprint BEFORE = ' || v_fp_before
    || E'\\nok   merge-on-verify migration applied inside this still-open transaction (against the REAL current live state)'
    || E'\\n--- merge-on-verify test output ---' || E'\\n' || coalesce(v_merge_test_result, '(test raised no exception -- unexpected)') || E'\\n--- end merge-on-verify test output ---'
    || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after
    || E'\\n' || case when v_fp_after is distinct from v_fp_before
         then 'FAIL real customer rows CHANGED -- this rehearsal mutated real data'
         else 'ok   every REAL customer''s own state unchanged -- this rehearsal mutated no real data' end;

  raise exception E'RESULTS:\\n%', res;
end
$rehearsal$;
`
}

function mergeApplySql({ dryrun }) {
  const dryrunRaise = dryrun
    ? `  raise exception 'DRYRUN_OK: this exact apply script compiles cleanly -- stopped at the first statement by design, nothing below this line ran, nothing committed';\n\n`
    : ""
  return `-- ${dryrun ? "DRYRUN-OK copy of the " : ""}GO APPLY script for migration ${MERGE_VERSION}_customer_link_otp_merge_on_verify.sql
-- (WP1: merge-on-verify + claim-own-number + needs_review flagging), branch feat/customer-otp-link.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file
${dryrun
    ? "-- except as a DRYRUN (see below) through the sha256-verified supabase/ops/run_rehearsal.mjs."
    : "-- (standing hard rule). The owner (or the coordinator, per this engagement's own division of\n-- labor) runs this by hand, after 11:00 IST and after typing the exact word \"APPROVED\" for this\n-- specific migration, once satisfied the sha256-pinned migration text embedded below is\n-- byte-for-byte the reviewed migration file."}

drop table if exists pg_temp.merge_on_verify_apply_status;
create temp table merge_on_verify_apply_status (
  migration_version text,
  version_registered boolean,
  functions_updated boolean,
  column_added boolean,
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
  v_expected_migration_hash text := '${hashes.merge}';
  v_actual_migration_hash text;
  v_migration_version text := '${MERGE_VERSION}';
  v_already_registered boolean;
  v_embedded_migration text := $migration$${texts.merge}$migration$;
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
    raise exception 'APPLY_REFUSED: prerequisite migration 20261121100100 is not applied live yet';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customers' and column_name='auto_link_blocked_at') then
    raise exception 'APPLY_REFUSED: prerequisite migration 20261121100150 / 20261130100000 is not applied live yet';
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
  values (v_migration_version, 'customer_link_otp_merge_on_verify', array[replace(v_embedded_migration, E'\\r', '')]);

  if (select prosrc from pg_proc where oid = 'public.request_customer_link_code(text)'::regprocedure) not like '%v_caller_customer_id%'
     or (select prosrc from pg_proc where oid = 'public.verify_customer_link_code(text)'::regprocedure) not like '%customer_link_otp_merge%' then
    raise exception 'APPLY_REFUSED: post-apply check failed -- one of the two functions does not contain the new logic';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='customer_link_otp_challenges' and column_name='requested_mobile') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- requested_mobile column missing';
  end if;
  if has_function_privilege('anon', 'public.request_customer_link_code(text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.verify_customer_link_code(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.request_customer_link_code(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.verify_customer_link_code(text)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- grants changed';
  end if;

  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1;
  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)', v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  insert into pg_temp.merge_on_verify_apply_status (migration_version, version_registered, functions_updated, column_added, grants_unchanged, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (v_migration_version, true, true, true, true, v_org_fingerprint_before, v_org_fingerprint_after, now());
end
$apply$;

select * from pg_temp.merge_on_verify_apply_status;
`
}

fs.writeFileSync("supabase/ops/customer_link_otp_merge_on_verify.rehearsal.sql", combinedRehearsalSql())
console.log("wrote combined rehearsal.sql")
fs.writeFileSync("supabase/ops/20261130100100_customer_link_otp_merge_on_verify.apply.sql", mergeApplySql({ dryrun: false }))
console.log("wrote merge apply.sql")
fs.writeFileSync("supabase/ops/20261130100100_customer_link_otp_merge_on_verify.apply.dryrun.sql", mergeApplySql({ dryrun: true }))
console.log("wrote merge apply.dryrun.sql")
console.log("DONE")
