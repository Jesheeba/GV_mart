// One-off generator for the close_outstanding_reminders_bulk rehearsal wrapper.
// Not part of the app build. Splices the real migration + test file content in
// verbatim so the embedded text is guaranteed byte-identical to the source files.
import fs from "node:fs"
import crypto from "node:crypto"

const migrationPath = "supabase/migrations/20261116100000_close_outstanding_reminders_bulk.sql"
const testPath = "supabase/tests/close_outstanding_reminders_bulk.test.sql"
const outPath = "supabase/rehearsals/rehearsal_20261116100000_close_outstanding_reminders_bulk.sql"

const migrationText = fs.readFileSync(migrationPath, "utf8").replace(/\r/g, "")
const testText = fs.readFileSync(testPath, "utf8").replace(/\r/g, "")

function sha256(text) {
  return crypto.createHash("sha256").update(text, "utf8").digest("hex")
}

const migrationHash = sha256(migrationText)
const testHash = sha256(testText)

const out = `-- Rehearsal wrapper for 20261116100000_close_outstanding_reminders_bulk.sql +
-- supabase/tests/close_outstanding_reminders_bulk.test.sql.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file. The owner runs this
-- by hand, after 11:00 IST (this feature's established gate time -- matches every other apply script under
-- supabase/ops/2026111510*), once satisfied the sha256-pinned text embedded below for BOTH files is byte-for-byte
-- what they reviewed.
--
-- Same six-guarantee structure as every other rehearsal wrapper in this project (ORG CHECK, LOCK, GATE, PIN, RUN,
-- PROVE): this block ends in an unconditional RAISE EXCEPTION, so nothing it does can ever commit, independent of
-- whether the embedded test passes, fails, or the gate/pin refuses outright.
--
-- PROVE scope: close_outstanding_reminders_if_zero_bulk() only ever updates public.customer_outstanding_reminders
-- rows, and only for the calling org -- the fingerprint below covers every REAL (non __TEST_) org's reminder rows,
-- which must be byte-identical before and after (this migration adds a function; the embedded test's own __TEST_
-- rows are rolled back by its closing RAISE before the AFTER fingerprint is taken).
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash  text := '${migrationHash}';
  v_expected_test_hash       text := '${testHash}';
  v_actual_migration_hash    text;
  v_actual_test_hash         text;
  v_fp_before                text;
  v_fp_after                 text;
  v_inner_result             text;
  res                        text := '';
  v_embedded_migration        text := $migration$${migrationText}$migration$;
  v_embedded_test              text := $testbody$${testText}$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\\_\\_TEST%' escape '\\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  -- 2. GATE -- 11:00 IST
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this rehearsal only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\\r', ''), 'UTF8')), 'hex');

  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded MIGRATION text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded TEST text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  res := res || E'\\nok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || E', both embedded-text sha256 hashes verified';

  -- Real-organisation fingerprint BEFORE -- every real (non __TEST_) customer_outstanding_reminders row.
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_before
  from (
    select r.id::text || ':' || r.status::text || ':' || coalesce(r.closed_at::text, '-') as x
    from public.customer_outstanding_reminders r
    join public.organizations o on o.id = r.org_id
    where o.name not like '\\_\\_TEST%' escape '\\'
  ) real_rows;
  res := res || E'\\nINFO real-row fingerprint BEFORE = ' || v_fp_before;

  -- 4. RUN
  execute replace(v_embedded_migration, E'\\r', '');
  res := res || E'\\nok   migration applied inside this still-open transaction';

  begin
    execute replace(v_embedded_test, E'\\r', '');
    v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
  exception when others then
    v_inner_result := sqlerrm;
  end;
  res := res || E'\\n--- embedded test output ---\\n' || coalesce(v_inner_result, '(no result captured)') || E'\\n--- end embedded test output ---';

  -- 5. PROVE
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_after
  from (
    select r.id::text || ':' || r.status::text || ':' || coalesce(r.closed_at::text, '-') as x
    from public.customer_outstanding_reminders r
    join public.organizations o on o.id = r.org_id
    where o.name not like '\\_\\_TEST%' escape '\\'
  ) real_rows;
  res := res || E'\\nINFO real-row fingerprint AFTER  = ' || v_fp_after;
  res := res || E'\\n' || case when v_fp_after = v_fp_before
                          then 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data'
                          else 'FAIL real-organisation fingerprint CHANGED -- investigate before trusting anything above' end;

  raise exception E'RESULTS:%', res;
end
$rehearsal$;
`

fs.writeFileSync(outPath, out, "utf8")
console.log("Wrote", outPath)
console.log("migration sha256:", migrationHash)
console.log("test sha256:", testHash)
