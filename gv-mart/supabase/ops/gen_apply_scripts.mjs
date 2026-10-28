// Generator for the 7 apply+snapshot script pairs of the Accounts follow-up
// feature. Not itself a migration or a DB-touching script -- pure text
// generation, run once by hand to produce the committed .apply.sql/
// .snapshot.sql files. Embeds each migration's actual on-disk text (CR as-is)
// so the sha256 pin inside each apply script is always byte-accurate.
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

const ORG_FP = '6f891cf85011f08c2f22fb4a208d21bd';
const MIGDIR = path.join(import.meta.dirname, '..', 'migrations');
const OPSDIR = import.meta.dirname;

function sha(text) {
  return crypto.createHash('sha256').update(text.replace(/\r/g, ''), 'utf8').digest('hex');
}

function readMig(name) {
  return fs.readFileSync(path.join(MIGDIR, name + '.sql'), 'utf8');
}

// Postgres dollar-quote-safe embed: pick a tag not present in the text.
function pickTag(text, base) {
  let tag = base;
  let n = 0;
  while (text.includes('$' + tag + '$')) {
    n += 1;
    tag = base + n;
  }
  return tag;
}

function applyHeader({ version, title, commit, note }) {
  return `-- GO APPLY script for migration ${version}_${title}.sql
-- Accounts follow-up spec, commit ${commit} on feat/accounts-outstanding-followups.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file.
-- The owner (or an authorised operator) runs this by hand, after 11:00 IST, once the release's
-- DB phase (GV_mart\\_local_only\\reports\\release_2026-10-28\\release_log.md) shows fully
-- complete, and once an independent reviewer has approved this exact script.
--
-- Structure: one autocommitted CREATE TEMP TABLE for the status row, then ONE DO block (no
-- top-level BEGIN/COMMIT -- a standalone DO block under autocommit is already atomic), then a
-- read-only SELECT from the status table. Re-running this script after a successful apply is
-- always a safe no-op refusal (step 3: already-registered check), never a double-apply.
${note || ''}
`;
}

function buildApply({
  version, title, commit, note, statusCols, preChecks, postChecks, migrationText, extraDecl = '', beforeRunDecl = '',
}) {
  const tableName = title + '_apply_status';
  const migTag = pickTag(migrationText, 'migration');
  const colDefs = statusCols.map((c) => `  ${c.name.padEnd(28)}${c.type}`).join(',\n');
  const colNames = statusCols.map((c) => c.name).join(', ');
  const colVals = statusCols.map((c) => c.value).join(',\n    ');

  return `${applyHeader({ version, title, commit, note })}
-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.${tableName};
create temp table ${tableName} (
${colDefs}
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '${ORG_FP}';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '${sha(migrationText)}';
  v_actual_migration_hash    text;
  v_migration_version        text := '${version}';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];
${extraDecl}
  v_embedded_migration       text := $${migTag}$${migrationText}$${migTag}$;
begin
  -- 0. ORG CHECK
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

${beforeRunDecl}
  -- 4. LIVE-DEFINITION PRE-CHECKS
${preChecks}

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
  values (v_migration_version, '${title}', array[replace(v_embedded_migration, E'\\r', '')]);

  -- 9. POST-APPLY CHECKS
${postChecks}

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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed %% function(s) to PUBLIC/anon: %',
      v_newly_leaked;
  end if;

  -- 9y. real-organisation fingerprint unchanged (identity check, not a no-row-change guarantee --
  -- this migration may add rows elsewhere, but the organisation row itself is never touched).
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
  insert into pg_temp.${tableName} (${colNames})
  values (
    ${colVals}
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.${tableName};
`;
}

const COMMIT = '72b86b90423bda68c25559566b981a920798b750';

// ---------------------------------------------------------------------------
// 1. customer_outstanding_reminders_schema
// ---------------------------------------------------------------------------
{
  const version = '20261115100000';
  const title = 'customer_outstanding_reminders_schema';
  const migrationText = readMig(version + '_' + title);
  const preChecks = `  if to_regclass('public.customer_outstanding_reminders') is not null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminders already exists before this migration ran';
  end if;
  if to_regtype('public.customer_outstanding_reminder_status') is not null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminder_status already exists before this migration ran';
  end if;`;
  const postChecks = `  if to_regclass('public.customer_outstanding_reminders') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.customer_outstanding_reminders does not exist';
  end if;
  if not (select relrowsecurity from pg_class where oid = to_regclass('public.customer_outstanding_reminders')) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- RLS not enabled on customer_outstanding_reminders';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_outstanding_reminders' and policyname = 'customer_outstanding_reminders_select_master') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- select policy missing';
  end if;
  if has_table_privilege('anon', 'public.customer_outstanding_reminders', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon can select customer_outstanding_reminders';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'table_exists', type: 'boolean', value: `(to_regclass('public.customer_outstanding_reminders') is not null)` },
    { name: 'rls_and_policy_ok', type: 'boolean', value: 'true' },
    { name: 'anon_select_denied', type: 'boolean', value: `(not has_table_privilege('anon', 'public.customer_outstanding_reminders', 'SELECT'))` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 2. customer_outstanding_links_schema
// ---------------------------------------------------------------------------
{
  const version = '20261115100100';
  const title = 'customer_outstanding_links_schema';
  const migrationText = readMig(version + '_' + title);
  const preChecks = `  if to_regclass('public.customer_outstanding_links') is not null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_links already exists before this migration ran';
  end if;`;
  const postChecks = `  if to_regclass('public.customer_outstanding_links') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.customer_outstanding_links does not exist';
  end if;
  if not (select relrowsecurity from pg_class where oid = to_regclass('public.customer_outstanding_links')) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- RLS not enabled on customer_outstanding_links';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_outstanding_links' and policyname = 'customer_outstanding_links_select_master') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- select policy missing';
  end if;
  if has_table_privilege('anon', 'public.customer_outstanding_links', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon can select customer_outstanding_links';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'table_exists', type: 'boolean', value: `(to_regclass('public.customer_outstanding_links') is not null)` },
    { name: 'anon_select_denied', type: 'boolean', value: `(not has_table_privilege('anon', 'public.customer_outstanding_links', 'SELECT'))` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 3. customer_outstanding_report
// ---------------------------------------------------------------------------
{
  const version = '20261115100200';
  const title = 'customer_outstanding_report';
  const migrationText = readMig(version + '_' + title);
  const preChecks = `  if to_regprocedure('public.report_customer_outstanding(uuid,int)') is not null then
    raise exception 'APPLY_REFUSED: public.report_customer_outstanding already exists before this migration ran';
  end if;
  if to_regprocedure('public.report_customer_outstanding_detail(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.report_customer_outstanding_detail already exists before this migration ran';
  end if;
  if to_regclass('public.invoices_org_customer_outstanding_idx') is not null then
    raise exception 'APPLY_REFUSED: index invoices_org_customer_outstanding_idx already exists before this migration ran';
  end if;`;
  const postChecks = `  if to_regprocedure('public.report_customer_outstanding(uuid,int)') is null
     or to_regprocedure('public.report_customer_outstanding_detail(uuid)') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- report functions do not both exist';
  end if;
  if to_regclass('public.invoices_org_customer_outstanding_idx') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- partial index missing';
  end if;
  if has_function_privilege('anon', 'public.report_customer_outstanding(uuid,int)', 'EXECUTE')
     or has_function_privilege('anon', 'public.report_customer_outstanding_detail(uuid)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- a report function is executable by anon/PUBLIC';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'functions_exist', type: 'boolean', value: `(to_regprocedure('public.report_customer_outstanding(uuid,int)') is not null and to_regprocedure('public.report_customer_outstanding_detail(uuid)') is not null)` },
    { name: 'index_exists', type: 'boolean', value: `(to_regclass('public.invoices_org_customer_outstanding_idx') is not null)` },
    { name: 'functions_not_anon_executable', type: 'boolean', value: `(not has_function_privilege('anon', 'public.report_customer_outstanding(uuid,int)', 'EXECUTE') and not has_function_privilege('anon', 'public.report_customer_outstanding_detail(uuid)', 'EXECUTE'))` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 4. customer_outstanding_rpcs
// ---------------------------------------------------------------------------
{
  const version = '20261115100300';
  const title = 'customer_outstanding_rpcs';
  const migrationText = readMig(version + '_' + title);
  const FNS = [
    'public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)',
    'public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)',
    'public.close_customer_outstanding_reminder(uuid)',
    'public.cancel_customer_outstanding_reminder(uuid,text)',
    'public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)',
    'public.close_outstanding_reminders_if_zero(uuid)',
  ];
  const existsExpr = (fn) => `to_regprocedure('${fn}') is not null`;
  const notAnonExpr = (fn) => `not has_function_privilege('anon', '${fn}', 'EXECUTE')`;
  const preChecks = FNS.map((fn) => `  if ${existsExpr(fn)} then\n    raise exception 'APPLY_REFUSED: ${fn} already exists before this migration ran';\n  end if;`).join('\n');
  const postChecks = `  if not (${FNS.map(existsExpr).join(' and ')}) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 6 RPCs exist';
  end if;
  if not (${FNS.map(notAnonExpr).join(' and ')}) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one RPC is executable by anon/PUBLIC';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'all_6_functions_exist', type: 'boolean', value: `(${FNS.map(existsExpr).join(' and ')})` },
    { name: 'none_anon_executable', type: 'boolean', value: `(${FNS.map(notAnonExpr).join(' and ')})` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 5. tasks_customer_outstanding_guard -- the sensitive one: policy replace + trigger.
// ---------------------------------------------------------------------------
{
  const version = '20261115100400';
  const title = 'tasks_customer_outstanding_guard';
  const migrationText = readMig(version + '_' + title);
  const EXPECTED_POST_P3 = `((org_id = current_org_id()) AND (is_staff() OR (current_technician_id() IS NOT NULL)) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))`;
  const EXPECTED_OURS = `((org_id = current_org_id()) AND (is_staff() OR ((current_technician_id() IS NOT NULL) AND (ref_type IS DISTINCT FROM 'customer_outstanding'::text))) AND (is_ops_staff() OR (assignee_id = auth.uid()) OR (assigned_by = auth.uid())))`;
  const extraDecl = `  v_pre_qual                 text;\n  v_post_qual                text;\n`;
  const preChecks = `  if to_regprocedure('public._guard_customer_outstanding_task_ref()') is not null then
    raise exception 'APPLY_REFUSED: public._guard_customer_outstanding_task_ref() already exists before this migration ran';
  end if;
  select replace(regexp_replace(qual, '\\s+', ' ', 'g'), '  ', ' ') into v_pre_qual
    from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';
  if v_pre_qual is distinct from '${EXPECTED_POST_P3}' then
    raise exception 'APPLY_REFUSED: live tasks_select_internal does not match the expected post-P3 shape this migration assumes (got: %). P1a/P1b/P2/P3 (integration/p-series) must be live first.', v_pre_qual;
  end if;`;
  const postChecks = `  if to_regprocedure('public._guard_customer_outstanding_task_ref()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard function missing';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard trigger missing';
  end if;
  select replace(regexp_replace(qual, '\\s+', ' ', 'g'), '  ', ' ') into v_post_qual
    from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';
  if v_post_qual is distinct from '${EXPECTED_OURS}' then
    raise exception 'APPLY_REFUSED: post-apply check failed -- tasks_select_internal does not match the expected final shape (got: %)', v_post_qual;
  end if;
  if has_function_privilege('anon', 'public._guard_customer_outstanding_task_ref()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- guard function is executable by anon/PUBLIC';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'guard_trigger_exists', type: 'boolean', value: `(exists (select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal))` },
    { name: 'policy_matches_expected_final_shape', type: 'boolean', value: `(v_post_qual is not distinct from '${EXPECTED_OURS}')` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText, extraDecl });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 6. expense_categories_schema -- table + column on expenses + seed + backfill
// ---------------------------------------------------------------------------
{
  const version = '20261115110000';
  const title = 'expense_categories_schema';
  const migrationText = readMig(version + '_' + title);
  const preChecks = `  if to_regclass('public.expense_categories') is not null then
    raise exception 'APPLY_REFUSED: public.expense_categories already exists before this migration ran';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') then
    raise exception 'APPLY_REFUSED: expenses.category_id already exists before this migration ran';
  end if;`;
  const postChecks = `  if to_regclass('public.expense_categories') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.expense_categories does not exist';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- expenses.category_id missing';
  end if;
  if has_table_privilege('anon', 'public.expense_categories', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon can select expense_categories';
  end if;
  if (select count(*) from public.expense_categories ec where ec.org_id = (
        select o.id from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1
      ) and ec.is_system) <> 12 then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the real organisation was not seeded with exactly 12 system categories';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'table_and_column_exist', type: 'boolean', value: `(to_regclass('public.expense_categories') is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id'))` },
    { name: 'anon_select_denied', type: 'boolean', value: `(not has_table_privilege('anon', 'public.expense_categories', 'SELECT'))` },
    { name: 'real_org_seeded_12_system_categories', type: 'boolean', value: `((select count(*) from public.expense_categories ec where ec.org_id = (select o.id from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1) and ec.is_system) = 12)` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

// ---------------------------------------------------------------------------
// 7. expense_categories_rpcs
// ---------------------------------------------------------------------------
{
  const version = '20261115110100';
  const title = 'expense_categories_rpcs';
  const migrationText = readMig(version + '_' + title);
  const FNS = [
    'public.create_expense_category(text)',
    'public.rename_expense_category(uuid,text)',
    'public.deactivate_expense_category(uuid)',
    'public.delete_expense_category(uuid)',
  ];
  const existsExpr = (fn) => `to_regprocedure('${fn}') is not null`;
  const notAnonExpr = (fn) => `not has_function_privilege('anon', '${fn}', 'EXECUTE')`;
  const preChecks = FNS.map((fn) => `  if ${existsExpr(fn)} then\n    raise exception 'APPLY_REFUSED: ${fn} already exists before this migration ran';\n  end if;`).join('\n');
  const postChecks = `  if not (${FNS.map(existsExpr).join(' and ')}) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 4 category RPCs exist';
  end if;
  if not (${FNS.map(notAnonExpr).join(' and ')}) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one category RPC is executable by anon/PUBLIC';
  end if;`;
  const statusCols = [
    { name: 'migration_version', type: 'text', value: 'v_migration_version' },
    { name: 'version_registered', type: 'boolean', value: 'true' },
    { name: 'all_4_functions_exist', type: 'boolean', value: `(${FNS.map(existsExpr).join(' and ')})` },
    { name: 'none_anon_executable', type: 'boolean', value: `(${FNS.map(notAnonExpr).join(' and ')})` },
    { name: 'newly_leaked_functions', type: 'text[]', value: 'v_newly_leaked' },
    { name: 'org_fingerprint_before', type: 'text', value: 'v_org_fingerprint_before' },
    { name: 'org_fingerprint_after', type: 'text', value: 'v_org_fingerprint_after' },
    { name: 'applied_at', type: 'timestamptz', value: 'now()' },
  ];
  const sql = buildApply({ version, title, commit: COMMIT, statusCols, preChecks, postChecks, migrationText });
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.apply.sql`), sql);
}

console.log('all 7 apply scripts written');
