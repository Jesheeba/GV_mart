-- GO APPLY script for migration 20261115100000_customer_outstanding_reminders_schema.sql
-- Accounts follow-up spec, commit 72b86b90423bda68c25559566b981a920798b750 on feat/accounts-outstanding-followups.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file.
-- The owner (or an authorised operator) runs this by hand, after 11:00 IST, once the release's
-- DB phase (GV_mart\_local_only\reports\release_2026-10-28\release_log.md) shows fully
-- complete, and once an independent reviewer has approved this exact script.
--
-- Structure: one autocommitted CREATE TEMP TABLE for the status row, then ONE DO block (no
-- top-level BEGIN/COMMIT -- a standalone DO block under autocommit is already atomic), then a
-- read-only SELECT from the status table. Re-running this script after a successful apply is
-- always a safe no-op refusal (step 3: already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.customer_outstanding_reminders_schema_apply_status;
create temp table customer_outstanding_reminders_schema_apply_status (
  migration_version text,
  version_registered boolean,
  table_exists boolean,
  rls_and_policy_ok boolean,
  anon_select_denied boolean,
  newly_leaked_functions text[],
  org_fingerprint_before text,
  org_fingerprint_after text,
  applied_at timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '17e597fb5904b0c3bc8999bf99a47c86ed2c1793f56f07d4d7a07a3a26acf351';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115100000';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature B, step 1 of 5 — the new internal-only
-- "Reminder" entity for a customer's outstanding balance. No generic
-- Reminder module exists in this codebase (see DECISIONS.md D2); this
-- table is modeled on lead_followups' proven conventions (status enum,
-- RPC-only writes, no client write policy, set_updated_at + audit_master_
-- change) rather than inventing a cross-module reminder system the spec
-- never asked for.
--
-- Master-only (DECISIONS.md D6/D10): nothing under /accounts is open to
-- operation_admin/sales_admin today, so this stays consistent with that.
-- Never sends anything to a customer — purely a staff-visible row.

create type public.customer_outstanding_reminder_status as enum ('open', 'done', 'cancelled');

create table public.customer_outstanding_reminders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  due_at timestamptz not null,
  note text,
  status public.customer_outstanding_reminder_status not null default 'open',
  -- manual | system (auto-closed when outstanding reaches zero)
  source text not null default 'manual' check (source in ('manual', 'system')),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  closed_by uuid references public.profiles (id) on delete set null,
  closed_at timestamptz,
  close_reason text,
  updated_at timestamptz not null default now(),
  constraint customer_outstanding_reminders_done_has_close check (status <> 'done' or closed_at is not null),
  constraint customer_outstanding_reminders_cancelled_has_close check (status <> 'cancelled' or closed_at is not null),
  constraint customer_outstanding_reminders_system_has_reason check (source <> 'system' or close_reason is not null)
);

create index customer_outstanding_reminders_org_customer_idx on public.customer_outstanding_reminders (org_id, customer_id);
create index customer_outstanding_reminders_due_idx on public.customer_outstanding_reminders (org_id, due_at) where status = 'open';

alter table public.customer_outstanding_reminders enable row level security;
revoke all on public.customer_outstanding_reminders from public, anon, authenticated;

-- Read only; every write goes through SECURITY DEFINER RPCs (next migration).
create policy customer_outstanding_reminders_select_master on public.customer_outstanding_reminders
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.customer_outstanding_reminders to authenticated;

create trigger set_updated_at before update on public.customer_outstanding_reminders
  for each row execute function public.set_updated_at();
create trigger audit_customer_outstanding_reminders after insert or update or delete on public.customer_outstanding_reminders
  for each row execute function public.audit_master_change();
$migration$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
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


  -- 4. LIVE-DEFINITION PRE-CHECKS
  if to_regclass('public.customer_outstanding_reminders') is not null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminders already exists before this migration ran';
  end if;
  if to_regtype('public.customer_outstanding_reminder_status') is not null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminder_status already exists before this migration ran';
  end if;

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
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'APPLY_REFUSED: embedded migration text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  -- 7. RUN -- apply the pinned migration text verbatim (CR-tolerant).
  execute replace(v_embedded_migration, E'\r', '');

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version, name, statements)
  values (v_migration_version, 'customer_outstanding_reminders_schema', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regclass('public.customer_outstanding_reminders') is null then
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
  end if;

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

  -- 9y. real-organisation fingerprint unchanged (identity check, not a no-row-change guarantee --
  -- this migration may add rows elsewhere, but the organisation row itself is never touched).
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'APPLY_REFUSED: post-apply check failed -- real-organisation fingerprint changed (before %, after %)',
      v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 10. Every step above passed -- record the one status row.
  insert into pg_temp.customer_outstanding_reminders_schema_apply_status (migration_version, version_registered, table_exists, rls_and_policy_ok, anon_select_denied, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regclass('public.customer_outstanding_reminders') is not null),
    true,
    (not has_table_privilege('anon', 'public.customer_outstanding_reminders', 'SELECT')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_outstanding_reminders_schema_apply_status;
