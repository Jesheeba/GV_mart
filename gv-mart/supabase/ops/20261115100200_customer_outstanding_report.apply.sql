-- GO APPLY script for migration 20261115100200_customer_outstanding_report.sql
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
drop table if exists pg_temp.customer_outstanding_report_apply_status;
create temp table customer_outstanding_report_apply_status (
  migration_version           text,
  version_registered          boolean,
  functions_exist             boolean,
  index_exists                boolean,
  functions_not_anon_executableboolean,
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
  v_expected_migration_hash  text := '08cddc0f4f1756cf596e8c24f819d43def9d15dde646df5b658d6ca7078edb7f';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115100200';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature B, step 3 of 5 — the Customer Outstanding
-- read model. No such page/view existed anywhere before this (DECISIONS.md
-- D1); both functions reuse the EXACT predicate report_kpi_tiles' live
-- 'outstanding' tile already uses (sum(total - amount_paid) where
-- payment_status <> 'paid' and total - amount_paid > 0, excluding
-- is_test_customer), just grouped by customer instead of summed org-wide,
-- so the two numbers reconcile by construction. Both functions are
-- READ-ONLY on money (owner's condition 3) — neither writes anything.
-- Master-only (DECISIONS.md D6/D10).

create index invoices_org_customer_outstanding_idx
  on public.invoices (org_id, customer_id) where payment_status <> 'paid';

create or replace function public.report_customer_outstanding(p_cursor uuid default null, p_limit int default 50)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int,
  task_assignee_name text,
  task_status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding: master only';
  end if;

  return query
  with outstanding as (
    select
      i.customer_id as cid,
      sum(i.total - i.amount_paid) as outstanding_amount,
      min((i.created_at at time zone 'Asia/Kolkata')::date) as oldest_invoice_date
    from public.invoices i
    where i.org_id = v_org
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
    group by i.customer_id
  ),
  reminders as (
    select r.customer_id as cid, count(*)::int as open_count, min(r.due_at) as next_due_at
    from public.customer_outstanding_reminders r
    where r.org_id = v_org and r.status = 'open'
    group by r.customer_id
  ),
  tasks_agg as (
    select
      l.customer_id as cid,
      count(*)::int as open_count,
      -- single representative row (assignee/status of the most-recently-created open task) for the list tile
      (array_agg(p.full_name order by t.created_at desc))[1] as assignee_name,
      (array_agg(t.status::text order by t.created_at desc))[1] as status
    from public.customer_outstanding_links l
    join public.tasks t on t.id = l.task_id
    left join public.profiles p on p.id = t.assignee_id
    where l.org_id = v_org and t.status = 'open'
    group by l.customer_id
  )
  select
    o.cid,
    c.name,
    o.outstanding_amount,
    o.oldest_invoice_date,
    coalesce(rem.open_count, 0),
    rem.next_due_at,
    coalesce(ta.open_count, 0),
    ta.assignee_name,
    ta.status
  from outstanding o
  join public.customers c on c.id = o.cid
  left join reminders rem on rem.cid = o.cid
  left join tasks_agg ta on ta.cid = o.cid
  where p_cursor is null or o.cid > p_cursor
  order by o.cid
  limit greatest(1, least(p_limit, 200));
end;
$$;
revoke all on function public.report_customer_outstanding(uuid, int) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding(uuid, int) to authenticated;

create or replace function public.report_customer_outstanding_detail(p_customer uuid)
returns table (
  customer_id uuid,
  customer_name text,
  outstanding_amount numeric,
  oldest_invoice_date date,
  open_reminder_count int,
  next_reminder_at timestamptz,
  open_task_count int
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'report_customer_outstanding_detail: master only';
  end if;

  return query
  select
    c.id,
    c.name,
    coalesce((
      select sum(i.total - i.amount_paid) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
    ), 0),
    (select min((i.created_at at time zone 'Asia/Kolkata')::date) from public.invoices i
      where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0),
    (select count(*)::int from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select min(r.due_at) from public.customer_outstanding_reminders r
      where r.org_id = v_org and r.customer_id = p_customer and r.status = 'open'),
    (select count(*)::int from public.customer_outstanding_links l
      join public.tasks t on t.id = l.task_id
      where l.org_id = v_org and l.customer_id = p_customer and t.status = 'open')
  from public.customers c
  where c.id = p_customer and c.org_id = v_org;
end;
$$;
revoke all on function public.report_customer_outstanding_detail(uuid) from public, anon, authenticated;
grant execute on function public.report_customer_outstanding_detail(uuid) to authenticated;
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
  if to_regprocedure('public.report_customer_outstanding(uuid,int)') is not null then
    raise exception 'APPLY_REFUSED: public.report_customer_outstanding already exists before this migration ran';
  end if;
  if to_regprocedure('public.report_customer_outstanding_detail(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.report_customer_outstanding_detail already exists before this migration ran';
  end if;
  if to_regclass('public.invoices_org_customer_outstanding_idx') is not null then
    raise exception 'APPLY_REFUSED: index invoices_org_customer_outstanding_idx already exists before this migration ran';
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
  values (v_migration_version, 'customer_outstanding_report', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regprocedure('public.report_customer_outstanding(uuid,int)') is null
     or to_regprocedure('public.report_customer_outstanding_detail(uuid)') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- report functions do not both exist';
  end if;
  if to_regclass('public.invoices_org_customer_outstanding_idx') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- partial index missing';
  end if;
  if has_function_privilege('anon', 'public.report_customer_outstanding(uuid,int)', 'EXECUTE')
     or has_function_privilege('anon', 'public.report_customer_outstanding_detail(uuid)', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- a report function is executable by anon/PUBLIC';
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
    raise exception 'APPLY_REFUSED: post-apply check failed -- this migration newly exposed function(s) to PUBLIC/anon: %',
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
  insert into pg_temp.customer_outstanding_report_apply_status (migration_version, version_registered, functions_exist, index_exists, functions_not_anon_executable, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regprocedure('public.report_customer_outstanding(uuid,int)') is not null and to_regprocedure('public.report_customer_outstanding_detail(uuid)') is not null),
    (to_regclass('public.invoices_org_customer_outstanding_idx') is not null),
    (not has_function_privilege('anon', 'public.report_customer_outstanding(uuid,int)', 'EXECUTE') and not has_function_privilege('anon', 'public.report_customer_outstanding_detail(uuid)', 'EXECUTE')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_outstanding_report_apply_status;
