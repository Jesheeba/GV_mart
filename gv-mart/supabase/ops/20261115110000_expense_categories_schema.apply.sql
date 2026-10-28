-- GO APPLY script for migration 20261115110000_expense_categories_schema.sql
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
drop table if exists pg_temp.expense_categories_schema_apply_status;
create temp table expense_categories_schema_apply_status (
  migration_version           text,
  version_registered          boolean,
  table_and_column_exist      boolean,
  anon_select_denied          boolean,
  real_org_seeded_12_system_categoriesboolean,
  newly_leaked_functions      text[],
  org_fingerprint_before      text,
  org_fingerprint_after       text,
  applied_at                  timestamptz
);

-- 2. The apply itself -- one DO block, atomic as a whole.
do $apply$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before   text;
  v_org_fingerprint_after    text;
  v_expected_migration_hash  text := '08602c4654ec49e6dae5641ae7ab8fd301a78e4d6262ba92b1a409b26ea39acf';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115110000';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature A, step 1 of 3 — owner-managed expense
-- categories ("Under Category"), additive alongside the existing fixed
-- `expenses.category` enum (DECISIONS.md D9) — the enum, its RLS, and
-- every path that writes it (including HR/Staff-Salary's "Log to
-- Accounts", which writes category='salary') are untouched by this
-- migration. No overlap with feat/monthly-expenses-v2 (DECISIONS.md D8).

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  -- System categories (one per existing expense_category enum value, plus
  -- Incentives) are seeded per-org and can never be renamed, deactivated or
  -- deleted — enforced below by a trigger, not only by the RPCs.
  is_system boolean not null default false,
  enum_value public.expense_category,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index expense_categories_org_name_ci_idx on public.expense_categories (org_id, lower(name));
create unique index expense_categories_org_enum_idx on public.expense_categories (org_id, enum_value) where enum_value is not null;
create index expense_categories_org_idx on public.expense_categories (org_id);

alter table public.expense_categories enable row level security;
revoke all on public.expense_categories from public, anon, authenticated;

-- Matches expenses_select_master precedent (20260701091300_rls.sql):
-- category management is a master-only Accounts concern.
create policy expense_categories_select_master on public.expense_categories
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.expense_categories to authenticated;

create trigger set_updated_at before update on public.expense_categories
  for each row execute function public.set_updated_at();
create trigger audit_expense_categories after insert or update or delete on public.expense_categories
  for each row execute function public.audit_master_change();

-- Real DB enforcement (owner's condition 4: "enforced in DB, not only
-- UI") that a system category's name/active flag can never change, and it
-- can never be deleted. The RPCs add a friendlier error on top of this.
create or replace function public._guard_expense_category_system_locked()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'expense_categories: a system category cannot be deleted';
    end if;
    return old;
  end if;
  if old.is_system and (new.name is distinct from old.name or new.is_active is distinct from old.is_active) then
    raise exception 'expense_categories: a system category cannot be renamed or deactivated';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_expense_category_system_locked() from public, anon, authenticated;

drop trigger if exists aaa_guard_expense_category_system_locked on public.expense_categories;
create trigger aaa_guard_expense_category_system_locked
  before update or delete on public.expense_categories
  for each row execute function public._guard_expense_category_system_locked();

-- Additive nullable FK — existing rows stay "uncategorised"; the existing
-- `category` enum column is never touched.
alter table public.expenses add column if not exists category_id uuid references public.expense_categories (id) on delete set null;
create index if not exists expenses_category_id_idx on public.expenses (category_id);

-- ── seed: one system category per existing enum value, plus Incentives ──
create or replace function public.seed_system_expense_categories(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.expense_categories (org_id, name, is_system, enum_value)
  values
    (p_org_id, 'Marketing Expenses', true, 'marketing'),
    (p_org_id, 'Stationery', true, 'stationery'),
    (p_org_id, 'Salary', true, 'salary'),
    (p_org_id, 'Petrol', true, 'petrol'),
    (p_org_id, 'Purchase', true, 'purchase'),
    (p_org_id, 'Other', true, 'other'),
    (p_org_id, 'Rent', true, 'rent'),
    (p_org_id, 'Electricity', true, 'electricity'),
    (p_org_id, 'Parking', true, 'parking'),
    (p_org_id, 'Ad Campaign', true, 'ad_campaign'),
    (p_org_id, 'Video Generation', true, 'video_generation'),
    (p_org_id, 'Incentives', true, null)
  on conflict (org_id, lower(name)) do nothing;
$$;
revoke execute on function public.seed_system_expense_categories(uuid) from public, anon, authenticated;

select public.seed_system_expense_categories(id) from public.organizations;

create or replace function public._trg_seed_system_expense_categories()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_system_expense_categories(new.id);
  return new;
end;
$$;
revoke all on function public._trg_seed_system_expense_categories() from public, anon, authenticated;

drop trigger if exists seed_system_expense_categories_on_org on public.organizations;
create trigger seed_system_expense_categories_on_org after insert on public.organizations
  for each row execute function public._trg_seed_system_expense_categories();

-- Idempotent, additive: only ever fills a null category_id, never
-- overwrites one a user later picked manually. Safe to re-run.
update public.expenses e
  set category_id = (
    select ec.id from public.expense_categories ec
    where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system
  )
  where e.category_id is null;
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
  if to_regclass('public.expense_categories') is not null then
    raise exception 'APPLY_REFUSED: public.expense_categories already exists before this migration ran';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') then
    raise exception 'APPLY_REFUSED: expenses.category_id already exists before this migration ran';
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
  values (v_migration_version, 'expense_categories_schema', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regclass('public.expense_categories') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- public.expense_categories does not exist';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- expenses.category_id missing';
  end if;
  if has_table_privilege('anon', 'public.expense_categories', 'SELECT') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- anon can select expense_categories';
  end if;
  if (select count(*) from public.expense_categories ec where ec.org_id = (
        select o.id from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1
      ) and ec.is_system) <> 12 then
    raise exception 'APPLY_REFUSED: post-apply check failed -- the real organisation was not seeded with exactly 12 system categories';
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed %% function(s) to PUBLIC/anon: %',
      v_newly_leaked;
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
  insert into pg_temp.expense_categories_schema_apply_status (migration_version, version_registered, table_and_column_exist, anon_select_denied, real_org_seeded_12_system_categories, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regclass('public.expense_categories') is not null and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id')),
    (not has_table_privilege('anon', 'public.expense_categories', 'SELECT')),
    ((select count(*) from public.expense_categories ec where ec.org_id = (select o.id from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1) and ec.is_system) = 12),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.expense_categories_schema_apply_status;
