-- GO APPLY script for migration 20261115100300_customer_outstanding_rpcs.sql
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
drop table if exists pg_temp.customer_outstanding_rpcs_apply_status;
create temp table customer_outstanding_rpcs_apply_status (
  migration_version text,
  version_registered boolean,
  all_6_functions_exist boolean,
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
  v_expected_migration_hash  text := 'cff1fb33c32550521ed261c8de26bc270c83e4119535f8fdbb6d3eb251e65f50';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261115100300';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature B, step 4 of 5 — create/reschedule/close/
-- cancel reminders, create a linked task, and the zero-outstanding
-- auto-close. All master-only SECURITY DEFINER, all RPC-only writes
-- (customer_outstanding_reminders/_links have no client write policy).
--
-- close_outstanding_reminders_if_zero is explicitly NOT a trigger on
-- invoices/sales/receipts/payments (owner's condition 2) — it is called
-- by the client after a payment succeeds, and opportunistically when the
-- Customer Outstanding detail view loads. It never touches `tasks`
-- (spec: never auto-complete a task).

create or replace function public.create_customer_outstanding_reminder(
  p_customer uuid, p_due_at timestamptz, p_note text default null, p_invoice uuid default null, p_amount numeric default 0
)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_reminder: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_reminder: customer not found in this organisation';
  end if;

  insert into public.customer_outstanding_reminders (org_id, customer_id, due_at, note)
  values (v_org, p_customer, p_due_at, p_note)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, reminder_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric) to authenticated;

create or replace function public.reschedule_customer_outstanding_reminder(p_reminder uuid, p_due_at timestamptz, p_note text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'reschedule_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set due_at = p_due_at, note = coalesce(p_note, note)
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'reschedule_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text) to authenticated;

create or replace function public.close_customer_outstanding_reminder(p_reminder uuid)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'done', closed_by = auth.uid(), closed_at = now()
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'close_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.close_customer_outstanding_reminder(uuid) from public, anon, authenticated;
grant execute on function public.close_customer_outstanding_reminder(uuid) to authenticated;

create or replace function public.cancel_customer_outstanding_reminder(p_reminder uuid, p_reason text default null)
returns public.customer_outstanding_reminders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.customer_outstanding_reminders;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'cancel_customer_outstanding_reminder: master only';
  end if;
  update public.customer_outstanding_reminders
    set status = 'cancelled', closed_by = auth.uid(), closed_at = now(), close_reason = p_reason
    where id = p_reminder and org_id = v_org and status = 'open'
    returning * into v_row;
  if v_row.id is null then
    raise exception 'cancel_customer_outstanding_reminder: reminder % is not open or not found', p_reminder;
  end if;
  return v_row;
end;
$$;
revoke all on function public.cancel_customer_outstanding_reminder(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_customer_outstanding_reminder(uuid, text) to authenticated;

-- Task side: reuses tasks.ref_type/ref_id (no new tasks columns). Master-
-- only write enforced a second, independent way by the trigger in the
-- next migration (_guard_customer_outstanding_task_ref), so this RPC's own
-- is_master() check is belt-and-suspenders, not the only gate.
create or replace function public.create_customer_outstanding_task(
  p_customer uuid, p_assignee uuid, p_title text, p_due_date date, p_invoice uuid default null, p_amount numeric default 0
)
returns public.tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.tasks;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_customer_outstanding_task: master only';
  end if;
  if not exists (select 1 from public.customers where id = p_customer and org_id = v_org) then
    raise exception 'create_customer_outstanding_task: customer not found in this organisation';
  end if;

  insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
  values (v_org, p_assignee, auth.uid(), p_title, p_due_date, 'manual', 'customer_outstanding', p_customer)
  returning * into v_row;

  insert into public.customer_outstanding_links (org_id, task_id, customer_id, invoice_id, amount_snapshot)
  values (v_org, v_row.id, p_customer, p_invoice, coalesce(p_amount, 0));

  return v_row;
end;
$$;
revoke all on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) from public, anon, authenticated;
grant execute on function public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric) to authenticated;

-- Zero-outstanding auto-close (owner's condition 2: computed on read / by
-- an RPC, never a trigger on a money table; does not touch tasks).
create or replace function public.close_outstanding_reminders_if_zero(p_customer uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero: master only';
  end if;

  select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
  from public.invoices i
  where i.org_id = v_org and i.customer_id = p_customer and i.payment_status <> 'paid' and i.total - i.amount_paid > 0;

  if v_outstanding > 0 then
    return 0;
  end if;

  with closed as (
    update public.customer_outstanding_reminders
      set status = 'done', source = 'system', closed_by = null, closed_at = now(),
          close_reason = 'outstanding reached zero'
      where org_id = v_org and customer_id = p_customer and status = 'open'
      returning 1
  )
  select count(*) into v_closed from closed;

  return v_closed;
end;
$$;
revoke all on function public.close_outstanding_reminders_if_zero(uuid) from public, anon, authenticated;
grant execute on function public.close_outstanding_reminders_if_zero(uuid) to authenticated;
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
  if to_regprocedure('public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)') is not null then
    raise exception 'APPLY_REFUSED: public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric) already exists before this migration ran';
  end if;
  if to_regprocedure('public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)') is not null then
    raise exception 'APPLY_REFUSED: public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text) already exists before this migration ran';
  end if;
  if to_regprocedure('public.close_customer_outstanding_reminder(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.close_customer_outstanding_reminder(uuid) already exists before this migration ran';
  end if;
  if to_regprocedure('public.cancel_customer_outstanding_reminder(uuid,text)') is not null then
    raise exception 'APPLY_REFUSED: public.cancel_customer_outstanding_reminder(uuid,text) already exists before this migration ran';
  end if;
  if to_regprocedure('public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)') is not null then
    raise exception 'APPLY_REFUSED: public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric) already exists before this migration ran';
  end if;
  if to_regprocedure('public.close_outstanding_reminders_if_zero(uuid)') is not null then
    raise exception 'APPLY_REFUSED: public.close_outstanding_reminders_if_zero(uuid) already exists before this migration ran';
  end if;
  if to_regclass('public.tasks') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'id' and data_type = 'uuid')
  then
    raise exception 'APPLY_REFUSED: public.tasks (uuid id) not found -- this migration reads/writes it';
  end if;
  if to_regclass('public.customer_outstanding_reminders') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customer_outstanding_reminders' and column_name = 'id' and data_type = 'uuid')
  then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminders (uuid id) not found -- run 20261115100000_customer_outstanding_reminders_schema first';
  end if;
  if to_regclass('public.customer_outstanding_links') is null
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customer_outstanding_links' and column_name = 'id' and data_type = 'uuid')
  then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_links (uuid id) not found -- run 20261115100100_customer_outstanding_links_schema first';
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
  values (v_migration_version, 'customer_outstanding_rpcs', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if not (to_regprocedure('public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)') is not null and to_regprocedure('public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)') is not null and to_regprocedure('public.close_customer_outstanding_reminder(uuid)') is not null and to_regprocedure('public.cancel_customer_outstanding_reminder(uuid,text)') is not null and to_regprocedure('public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)') is not null and to_regprocedure('public.close_outstanding_reminders_if_zero(uuid)') is not null) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- not all 6 RPCs exist';
  end if;
  if not (not has_function_privilege('anon', 'public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)', 'EXECUTE') and not has_function_privilege('anon', 'public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.close_customer_outstanding_reminder(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.cancel_customer_outstanding_reminder(uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)', 'EXECUTE') and not has_function_privilege('anon', 'public.close_outstanding_reminders_if_zero(uuid)', 'EXECUTE')) then
    raise exception 'APPLY_REFUSED: post-apply check failed -- at least one RPC is executable by anon/PUBLIC';
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
  insert into pg_temp.customer_outstanding_rpcs_apply_status (migration_version, version_registered, all_6_functions_exist, none_anon_executable, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regprocedure('public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)') is not null and to_regprocedure('public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)') is not null and to_regprocedure('public.close_customer_outstanding_reminder(uuid)') is not null and to_regprocedure('public.cancel_customer_outstanding_reminder(uuid,text)') is not null and to_regprocedure('public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)') is not null and to_regprocedure('public.close_outstanding_reminders_if_zero(uuid)') is not null),
    (not has_function_privilege('anon', 'public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)', 'EXECUTE') and not has_function_privilege('anon', 'public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.close_customer_outstanding_reminder(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'public.cancel_customer_outstanding_reminder(uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)', 'EXECUTE') and not has_function_privilege('anon', 'public.close_outstanding_reminders_if_zero(uuid)', 'EXECUTE')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.customer_outstanding_rpcs_apply_status;
