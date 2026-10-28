-- GO APPLY script for migration 20261115110100_expense_categories_rpcs.sql
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
drop table if exists pg_temp.expense_categories_rpcs_apply_status;
create temp table expense_categories_rpcs_apply_status (
  migration_version text,
  version_registered boolean,
  all_4_functions_exist boolean,
  none_anon_executable boolean,
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
  v_expected_migration_hash  text := 'c7c523fc9afb8cf384aa15f331ef232fb5518745032cab90acf869eb8d827a5a';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115110100';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature A, step 2 of 3 — owner-managed category
-- create/rename/deactivate/delete, all master-only SECURITY DEFINER.
-- The real enforcement that a system category is locked lives in the
-- trigger (previous migration); these checks are a friendlier error for
-- the UI.

create or replace function public.create_expense_category(p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_expense_category: master only';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'create_expense_category: name is required';
  end if;

  insert into public.expense_categories (org_id, name)
  values (v_org, btrim(p_name))
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'create_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.create_expense_category(text) from public, anon, authenticated;
grant execute on function public.create_expense_category(text) to authenticated;

create or replace function public.rename_expense_category(p_id uuid, p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'rename_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'rename_expense_category: a system category cannot be renamed';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'rename_expense_category: name is required';
  end if;

  update public.expense_categories
    set name = btrim(p_name)
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'rename_expense_category: category % not found', p_id;
  end if;
  return v_row;
exception
  when unique_violation then
    raise exception 'rename_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.rename_expense_category(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_expense_category(uuid, text) to authenticated;

create or replace function public.deactivate_expense_category(p_id uuid)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'deactivate_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'deactivate_expense_category: a system category cannot be deactivated';
  end if;

  update public.expense_categories
    set is_active = false
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'deactivate_expense_category: category % not found', p_id;
  end if;
  return v_row;
end;
$$;
revoke all on function public.deactivate_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.deactivate_expense_category(uuid) to authenticated;

create or replace function public.delete_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_deleted int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'delete_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'delete_expense_category: a system category cannot be deleted';
  end if;
  if exists (select 1 from public.expenses where category_id = p_id) then
    raise exception 'delete_expense_category: category % is used by at least one expense', p_id;
  end if;

  delete from public.expense_categories where id = p_id and org_id = v_org;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'delete_expense_category: category % not found', p_id;
  end if;
end;
$$;
revoke all on function public.delete_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.delete_expense_category(uuid) to authenticated;
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
  if to_regprocedure('public.create_expense_category(text)') is not null then
    raise exception 'APPLY_REFUSED: public.create_expense_category(text) already exists before this migration ran';
  end if;
  if to_regprocedure('public.rename_expense_category(uuid,text)') is not null then
    raise exception 'APPLY_REFUSED: public.rename_expense_category(uuid,text) already exists before this migration ran';
  end if;
  if to_regprocedure('public.deactivate_expense_category(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.deactivate_expense_category(uuid) already exists before this migration ran';
  end if;
  if to_regprocedure('public.delete_expense_category(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.delete_expense_category(uuid) already exists before this migration ran';
  end if;
  if to_regclass('public.expense_categories') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id')
  then
    raise exception 'APPLY_REFUSED: public.expense_categories / expenses.category_id not found -- run 20261115110000_expense_categories_schema first';
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
  values (v_migration_version, 'expense_categories_rpcs', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if not (to_regprocedure('public.create_expense_category(text)') is not null and to_regprocedure('public.rename_expense_category(uuid,text)') is not null and to_regprocedure('public.deactivate_expense_category(uuid)') is not null and to_regprocedure('public.delete_expense_category(uuid)') is not null) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 4 category RPCs exist';
  end if;
  if not (not has_function_privilege('anon', 'public.create_expense_category(text)', 'EXECUTE') and not has_function_privilege('anon', 'public.rename_expense_category(uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.deactivate_expense_category(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.delete_expense_category(uuid)', 'EXECUTE')) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one category RPC is executable by anon/PUBLIC';
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
  insert into pg_temp.expense_categories_rpcs_apply_status (migration_version, version_registered, all_4_functions_exist, none_anon_executable, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regprocedure('public.create_expense_category(text)') is not null and to_regprocedure('public.rename_expense_category(uuid,text)') is not null and to_regprocedure('public.deactivate_expense_category(uuid)') is not null and to_regprocedure('public.delete_expense_category(uuid)') is not null),
    (not has_function_privilege('anon', 'public.create_expense_category(text)', 'EXECUTE') and not has_function_privilege('anon', 'public.rename_expense_category(uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.deactivate_expense_category(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.delete_expense_category(uuid)', 'EXECUTE')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.expense_categories_rpcs_apply_status;
