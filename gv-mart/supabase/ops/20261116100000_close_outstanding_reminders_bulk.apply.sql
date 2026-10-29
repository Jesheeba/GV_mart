-- GO APPLY script for migration 20261116100000_close_outstanding_reminders_bulk.sql
-- Accounts follow-up, reminder management batch, on feat/accounts-outstanding-management.
--
-- WRITTEN ONLY -- never executed against any database by the agent that produced this file.
-- The owner (or an authorised operator) runs this by hand, after 11:00 IST, once rehearsed
-- (supabase/rehearsals/rehearsal_20261116100000_close_outstanding_reminders_bulk.sql) and once
-- an independent reviewer has approved this exact script.
--
-- Structure: one autocommitted CREATE TEMP TABLE for the status row, then ONE DO block (no
-- top-level BEGIN/COMMIT -- a standalone DO block under autocommit is already atomic), then a
-- read-only SELECT from the status table. Re-running this script after a successful apply is
-- always a safe no-op refusal (step 3: already-registered check), never a double-apply.


-- 1. Status table -- autocommitted on its own, independent of the DO block's outcome.
drop table if exists pg_temp.close_outstanding_reminders_bulk_apply_status;
create temp table close_outstanding_reminders_bulk_apply_status (
  migration_version text,
  version_registered boolean,
  function_exists boolean,
  anon_execute_denied boolean,
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
  v_expected_migration_hash  text := 'c7b19159782b85ee79f9a32bb4e7de50a49b18eb520c18fefb8ca928ac9cd4ba';
  v_actual_migration_hash    text;
  v_migration_version        text := '20261116100000';
  v_already_registered       boolean;
  v_leaked_before            text[];
  v_leaked_after             text[];
  v_newly_leaked             text[];

  v_embedded_migration       text := $migration$-- Accounts follow-up, reminder management batch, item 2 — auto-close ALL
-- open customer-outstanding reminders whose customer's balance has reached
-- zero, computed on read (owner's condition: no trigger, no background job)
-- whenever the Customer Outstanding list or the new Reminders view loads,
-- not only when one customer's own "Follow up" dialog opens.
--
-- This is the same logic close_outstanding_reminders_if_zero (20261115100300)
-- already runs for a single customer, generalised into a loop over every
-- customer in this org that currently has an open reminder. No money table
-- is touched or written to -- only customer_outstanding_reminders rows are
-- updated, exactly as the existing per-customer version does.

create or replace function public.close_outstanding_reminders_if_zero_bulk()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_org_id();
  v_total_closed int := 0;
  v_customer record;
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero_bulk: master only';
  end if;

  for v_customer in
    select distinct customer_id
    from public.customer_outstanding_reminders
    where org_id = v_org and status = 'open'
  loop
    select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
    from public.invoices i
    where i.org_id = v_org
      and i.customer_id = v_customer.customer_id
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0;

    if v_outstanding <= 0 then
      with closed as (
        update public.customer_outstanding_reminders
          set status = 'done', source = 'system', closed_by = null, closed_at = now(),
              close_reason = 'outstanding reached zero'
          where org_id = v_org and customer_id = v_customer.customer_id and status = 'open'
          returning 1
      )
      select count(*) into v_closed from closed;
      v_total_closed := v_total_closed + v_closed;
    end if;
  end loop;

  return v_total_closed;
end;
$function$;
revoke all on function public.close_outstanding_reminders_if_zero_bulk() from public, anon;
grant execute on function public.close_outstanding_reminders_if_zero_bulk() to authenticated;
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
  if to_regprocedure('public.close_outstanding_reminders_if_zero_bulk()') is not null then
    raise exception 'APPLY_REFUSED: public.close_outstanding_reminders_if_zero_bulk() already exists before this migration ran';
  end if;
  if to_regclass('public.customer_outstanding_reminders') is null then
    raise exception 'APPLY_REFUSED: public.customer_outstanding_reminders not found -- this migration depends on 20261115100000 already being live';
  end if;
  if to_regprocedure('public.is_master()') is null then
    raise exception 'APPLY_REFUSED: public.is_master() not found -- this migration depends on it already existing';
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
  values (v_migration_version, 'close_outstanding_reminders_bulk', array[replace(v_embedded_migration, E'\r', '')]);

  -- 9. POST-APPLY CHECKS
  if to_regprocedure('public.close_outstanding_reminders_if_zero_bulk()') is null then
    raise exception 'APPLY_REFUSED: post-apply check failed -- function missing';
  end if;
  if has_function_privilege('anon', 'public.close_outstanding_reminders_if_zero_bulk()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- function is executable by anon';
  end if;
  if not has_function_privilege('authenticated', 'public.close_outstanding_reminders_if_zero_bulk()', 'EXECUTE') then
    raise exception 'APPLY_REFUSED: post-apply check failed -- function is NOT executable by authenticated (the app would break)';
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

  -- 9y. real-organisation fingerprint unchanged.
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
  insert into pg_temp.close_outstanding_reminders_bulk_apply_status (migration_version, version_registered, function_exists, anon_execute_denied, newly_leaked_functions, org_fingerprint_before, org_fingerprint_after, applied_at)
  values (
    v_migration_version,
    true,
    (to_regprocedure('public.close_outstanding_reminders_if_zero_bulk()') is not null),
    (not has_function_privilege('anon', 'public.close_outstanding_reminders_if_zero_bulk()', 'EXECUTE')),
    v_newly_leaked,
    v_org_fingerprint_before,
    v_org_fingerprint_after,
    now()
  );
end
$apply$;

-- 3. The actual thing to look at: one row on success, zero rows if the DO block raised and rolled back.
select * from pg_temp.close_outstanding_reminders_bulk_apply_status;
