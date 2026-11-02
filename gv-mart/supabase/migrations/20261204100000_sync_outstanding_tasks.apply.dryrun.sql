-- Rehearsal wrapper -- generated from gen_rehearsal.mjs, following this project's
-- standing rehearsal convention (see supabase/ops/technician_pending_reviews.rehearsal.sql):
-- ORG CHECK, LOCK (5s lock_timeout, this transaction only), GATE (11:00 IST), PIN
-- (CR-tolerant sha256 of the embedded migration + test text), RUN (apply migration +
-- run test, both inside this one transaction), PROVE (real, non-__TEST_ row
-- fingerprint before/after must be identical), unconditional closing
-- RAISE EXCEPTION E'RESULTS:%' so this can never itself commit anything live no
-- matter how it exits.
do $rehearsal$
declare
  v_ist_hour                 int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_actual_org_fingerprint   text;
  v_expected_migration_hash  text := 'd644ccd766fe908f3c62494212cc889460cab0f73ff4df677e00b3d82928ed51';
  v_expected_test_hash       text := '3937cb404b0d342f2534eed2cd76b1d00acce560a851d8533a2afa8b0028d655';
  v_actual_migration_hash    text;
  v_actual_test_hash         text;
  v_fp_before                text;
  v_fp_after                 text;
  v_inner_result             text;
  res                        text := '';
  v_embedded_migration       text := $migration$-- Accounts follow-up, Feature B step 6 (client-requested, 2026-11-02): no
-- triggers on invoices/payments. Instead a SECURITY DEFINER sync -- run
-- daily by cron plus a master-only "Refresh" button -- creates or refreshes
-- one open customer_outstanding task per customer (title shows total due +
-- invoice count), applies a master-editable minimum-balance / minimum-age
-- threshold, assigns a master-editable default owner (falling back to the
-- org's master), and closes the task once the balance reaches zero.
-- Idempotent: re-running with nothing changed makes no writes. Never
-- contacts a customer -- purely an internal task/reminder sync, same as
-- the existing customer_outstanding_* conventions.

-- ── settings: threshold + default owner ──────────────────────────────────
alter table public.settings add column if not exists min_outstanding_balance numeric(12,2) not null default 50 check (min_outstanding_balance >= 0);
alter table public.settings add column if not exists min_outstanding_days integer not null default 3 check (min_outstanding_days >= 0);
alter table public.settings add column if not exists default_accounts_owner_id uuid references public.profiles (id) on delete set null;

comment on column public.settings.min_outstanding_balance is
  'Minimum unpaid balance (summed across a customer''s unpaid/partial invoices) before sync_outstanding_tasks opens a follow-up task for that customer. Master-editable, ships at 50.';
comment on column public.settings.min_outstanding_days is
  'Minimum age in days, since the customer''s oldest unpaid invoice, before sync_outstanding_tasks opens a follow-up task. Master-editable, ships at 3.';
comment on column public.settings.default_accounts_owner_id is
  'Who sync_outstanding_tasks assigns new customer-outstanding tasks to. Null (the default) falls back to the org''s active master at sync time; reassignment after creation still works through the normal task UI.';

-- ── tasks: enforce one open customer_outstanding task per customer ────────
-- Matches customer_outstanding_links' "exactly one target" discipline and
-- lead_followups' one-open-per-lead precedent -- same idea, applied here at
-- the customer level since this release groups by customer, not invoice.
create unique index if not exists tasks_customer_outstanding_one_open_idx
  on public.tasks (org_id, ref_id)
  where ref_type = 'customer_outstanding' and status = 'open';

-- ── internal, per-org sync -- NO grants to anon or authenticated. Reachable
-- only from the two trusted entry points below: sync_outstanding_tasks()
-- (the cron target, which loops every real org id itself) and
-- refresh_outstanding_tasks() (the master-only wrapper, which derives
-- org_id from current_org_id(), never from caller input). ─────────────────
create or replace function public._sync_outstanding_tasks_for_org(p_org_id uuid)
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_owner uuid;
  v_min_balance numeric;
  v_min_days integer;
  v_customer record;
  v_title text;
  v_existing_task_id uuid;
  v_existing_title text;
  v_created_or_updated int := 0;
  v_closed int := 0;
begin
  select coalesce(
           s.default_accounts_owner_id,
           (select p.id from public.profiles p
             where p.org_id = p_org_id and p.role = 'master' and p.is_active
             order by p.created_at asc limit 1)
         ),
         s.min_outstanding_balance,
         s.min_outstanding_days
    into v_owner, v_min_balance, v_min_days
  from public.settings s
  where s.org_id = p_org_id;

  if v_owner is null then
    -- no settings row, or no active master to fall back to -- nothing
    -- safe to assign a task to; skip this org for this run rather than
    -- raising and aborting every other org's sync.
    return 0;
  end if;

  for v_customer in
    select i.customer_id,
           sum(i.total - i.amount_paid) as outstanding,
           count(*) as invoice_count,
           min(i.created_at)::date as oldest_date,
           c.name as customer_name
    from public.invoices i
    join public.customers c on c.id = i.customer_id
    where i.org_id = p_org_id
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
    group by i.customer_id, c.name
  loop
    select t.id, t.title into v_existing_task_id, v_existing_title
    from public.tasks t
    where t.org_id = p_org_id
      and t.ref_type = 'customer_outstanding'
      and t.ref_id = v_customer.customer_id
      and t.status = 'open';

    if v_customer.outstanding >= v_min_balance
       and (current_date - v_customer.oldest_date) >= v_min_days then
      v_title := format('Follow up: %s outstanding (%s invoice%s) — %s',
                         to_char(v_customer.outstanding, 'FM999999999990.00'),
                         v_customer.invoice_count,
                         case when v_customer.invoice_count = 1 then '' else 's' end,
                         v_customer.customer_name);

      if v_existing_task_id is null then
        insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
        values (p_org_id, v_owner, v_owner, v_title, current_date, 'system', 'customer_outstanding', v_customer.customer_id);
        v_created_or_updated := v_created_or_updated + 1;
      elsif v_existing_title is distinct from v_title then
        update public.tasks set title = v_title, updated_at = now() where id = v_existing_task_id;
        v_created_or_updated := v_created_or_updated + 1;
      end if;
    end if;
    -- below-threshold-but-not-zero customers with an existing open task are
    -- deliberately left alone here -- only a real zero balance (below)
    -- closes a task, so a partial payment doesn't flip it open/closed
    -- every run.
  end loop;

  -- close every open customer_outstanding task whose customer now has zero
  -- qualifying outstanding (payment landed, credit note, etc).
  update public.tasks t
    set status = 'done', updated_at = now()
  where t.org_id = p_org_id
    and t.ref_type = 'customer_outstanding'
    and t.status = 'open'
    and not exists (
      select 1 from public.invoices i
      where i.org_id = p_org_id and i.customer_id = t.ref_id
        and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
    );
  get diagnostics v_closed = row_count;

  return v_created_or_updated + v_closed;
end;
$function$;

revoke all on function public._sync_outstanding_tasks_for_org(uuid) from public, anon, authenticated;

-- ── cron entry point: every real org, once a day ──────────────────────────
create or replace function public.sync_outstanding_tasks()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org record;
begin
  for v_org in select id from public.organizations loop
    perform public._sync_outstanding_tasks_for_org(v_org.id);
  end loop;
end;
$function$;

revoke all on function public.sync_outstanding_tasks() from public, anon, authenticated;

-- ── master-only wrapper for the Refresh button ────────────────────────────
create or replace function public.refresh_outstanding_tasks()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_org_id();
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'refresh_outstanding_tasks: master only';
  end if;
  return public._sync_outstanding_tasks_for_org(v_org);
end;
$function$;

revoke all on function public.refresh_outstanding_tasks() from public, anon, authenticated;
grant execute on function public.refresh_outstanding_tasks() to authenticated;

-- ── pg_cron schedule (daily, 06:00 IST = 00:30 UTC) ───────────────────────
-- Same unschedule-then-schedule idempotent shape as
-- 20261007120000_lead_followup_notifications.sql / 20261202100100_geocode_rate_limit.sql.
create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    perform cron.unschedule('sync-outstanding-tasks');
  end if;
  perform cron.schedule('sync-outstanding-tasks', '30 0 * * *', 'select public.sync_outstanding_tasks()');
end
$$;
$migration$;
  v_embedded_test            text := $testbody$do $sync_outstanding_test$
declare
  v_org uuid;
  v_master uuid;
  v_ops uuid;
  v_test_org_ops uuid;
  v_cust_a uuid;
  v_cust_b uuid;
  v_cust_c uuid;
  v_cust_zero uuid;
  v_inv1 uuid;
  v_inv2 uuid;
  v_inv3 uuid;
  v_inv_young uuid;
  v_inv_zero uuid;
  v_task_id uuid;
  v_task_id_again uuid;
  v_title text;
  v_count int;
  v_ok boolean;
  res text := '';
begin
  select o.id into v_org
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  select p.id into v_master
  from public.profiles p
  where p.org_id = v_org and p.role = 'master' and p.is_active
  limit 1;

  select p.id into v_ops
  from public.profiles p
  where p.org_id = v_org and p.role = 'operation_admin' and p.is_active
  limit 1;

  -- reuse the pre-existing "__TEST_ GV Mart 2026-10-12" org's own ops
  -- profile for the cross-org check below, instead of creating a brand
  -- new auth.users row inside this rehearsal.
  select p.id into v_test_org_ops
  from public.profiles p
  join public.organizations o2 on o2.id = p.org_id
  where o2.name = '__TEST_ GV Mart 2026-10-12' and p.role = 'operation_admin'
  limit 1;

  if v_org is null or v_master is null then
    raise exception 'TEST_SETUP: could not find the real org or its active master profile';
  end if;

  -- ── test fixtures (__TEST_-prefixed names, excluded from the forced-
  -- rollback real-row fingerprint below -- but deliberately NOT flagged
  -- is_test=true, since is_test_customer() is now excluded from this very
  -- sync's own aggregation (matching report_customer_outstanding's existing
  -- exclusion) and these rows need to actually be picked up to test it).
  -- Cleaned up by this whole rehearsal's forced rollback, never committed.
  insert into public.customers (org_id, name) values (v_org, '__TEST_sot_below') returning id into v_cust_a;
  insert into public.customers (org_id, name) values (v_org, '__TEST_sot_above') returning id into v_cust_b;
  insert into public.customers (org_id, name) values (v_org, '__TEST_sot_young') returning id into v_cust_c;
  insert into public.customers (org_id, name) values (v_org, '__TEST_sot_zero') returning id into v_cust_zero;

  -- customer A: below the 50 minimum (outstanding = 20)
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
    values (v_org, v_cust_a, 'product', 20, 0, 0, 20, 'due', 0, now() - interval '10 days')
    returning id into v_inv1;

  -- customer B: two invoices, 100 + 50 = 150 outstanding, oldest 10 days old
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
    values (v_org, v_cust_b, 'product', 100, 0, 0, 100, 'due', 0, now() - interval '10 days')
    returning id into v_inv2;
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
    values (v_org, v_cust_b, 'product', 50, 0, 0, 50, 'due', 0, now() - interval '5 days')
    returning id into v_inv3;

  -- customer C: above the balance minimum but the invoice is only 1 day old (< 3-day minimum)
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
    values (v_org, v_cust_c, 'product', 100, 0, 0, 100, 'due', 0, now() - interval '1 day')
    returning id into v_inv_young;

  -- customer ZERO: qualifies now, will be paid off below to test auto-close
  insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
    values (v_org, v_cust_zero, 'product', 80, 0, 0, 80, 'due', 0, now() - interval '10 days')
    returning id into v_inv_zero;

  -- ── run #1, impersonating the real master (also the "master succeeds" role test) ─
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.refresh_outstanding_tasks();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  select count(*) = 0 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_a and status = 'open';
  res := res || E'\ntest1 below-threshold customer (outstanding=20 < 50) gets no task (expect true): ' || v_ok;

  select t.id, t.title into v_task_id, v_title
    from public.tasks t
    where t.org_id = v_org and t.ref_type = 'customer_outstanding' and t.ref_id = v_cust_b and t.status = 'open';
  select count(*) into v_count from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_b and status = 'open';
  res := res || E'\ntest2 two-invoice customer B: exactly one open task (expect 1): ' || v_count;
  res := res || E'\ntest2b title: ' || coalesce(v_title, '(none)');
  res := res || E'\ntest2c title shows total 150.00 and "2 invoice" (expect true): '
    || ((v_title like '%150.00%') and (v_title like '%2 invoice%'));
  res := res || E'\ntest2d task assigned to the org''s active master via owner fallback (expect true): '
    || (select assignee_id = v_master from public.tasks where id = v_task_id);

  select count(*) = 0 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_c and status = 'open';
  res := res || E'\ntest3 invoice younger than the 3-day minimum gets no task yet (expect true): ' || v_ok;

  select count(*) = 1 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_zero and status = 'open';
  res := res || E'\ntest4 customer_zero (qualifies) gets exactly one open task (expect true): ' || v_ok;

  -- ── pay customer ZERO off in full, re-run -> its task should auto-close ─
  update public.invoices set amount_paid = total, payment_status = 'paid' where id = v_inv_zero;

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.refresh_outstanding_tasks();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  select count(*) = 0 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_zero and status = 'open';
  res := res || E'\ntest5 payment in full closes the task (expect true): ' || v_ok;
  select count(*) = 1 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_zero and status = 'done';
  res := res || E'\ntest5b the closed task is status=done, not deleted (expect true): ' || v_ok;

  -- ── run #2 (idempotency): customer B's task is unchanged, not duplicated ─
  select id into v_task_id
    from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_b and status = 'open';

  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.refresh_outstanding_tasks();
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_count from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_b and status = 'open';
  select id into v_task_id_again
    from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_b and status = 'open';
  res := res || E'\ntest6 second run: still exactly one open task for customer B (expect 1): ' || v_count;
  res := res || E'\ntest6b second run updated the SAME task row rather than creating a new one (expect true): '
    || (v_task_id = v_task_id_again);

  -- ── role test: an operation_admin cannot call the master-only wrapper ──
  if v_ops is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_ops, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      perform public.refresh_outstanding_tasks();
      res := res || E'\ntest7 operation_admin calls refresh_outstanding_tasks: SUCCEEDED (bad)';
    exception when others then
      res := res || E'\ntest7 operation_admin calls refresh_outstanding_tasks: rejected (good) -- ' || sqlerrm;
    end;
    execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  else
    res := res || E'\ntest7 SKIPPED -- no active operation_admin profile found in this org to impersonate';
  end if;

  -- ── cross-org: refresh_outstanding_tasks() takes no org parameter at all
  -- -- org is derived solely from current_org_id() of whichever profile is
  -- impersonated, so there is no argument through which any caller could
  -- ever reach another org's rows. Demonstrated two ways: (a) by signature
  -- -- grep confirms no uuid parameter exists on the granted wrapper; (b) by
  -- impersonating a real profile that belongs to a DIFFERENT, pre-existing
  -- org ("__TEST_ GV Mart 2026-10-12") and confirming the call only ever
  -- evaluates against ITS OWN org (and is rejected anyway, since that
  -- org has no master) -- it can never touch the real org's data.
  if v_test_org_ops is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_test_org_ops, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    begin
      perform public.refresh_outstanding_tasks();
      res := res || E'\ntest8 cross-org: __TEST_ org''s ops profile calls refresh_outstanding_tasks: SUCCEEDED (bad)';
    exception when others then
      res := res || E'\ntest8 cross-org: __TEST_ org''s ops profile calls refresh_outstanding_tasks: rejected (good) -- ' || sqlerrm;
    end;
    execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  else
    res := res || E'\ntest8 SKIPPED -- the pre-existing __TEST_ org''s ops profile was not found';
  end if;
  -- confirm that attempt (regardless of outcome) left the real org's B task untouched
  select count(*) = 1 into v_ok from public.tasks
    where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_b and status = 'open';
  res := res || E'\ntest8b real org''s customer B task is unaffected by the cross-org attempt (expect true): ' || v_ok;

  -- ── anon / PUBLIC cannot execute any of the three functions ────────────
  select
      not has_function_privilege('anon', 'public.refresh_outstanding_tasks()', 'EXECUTE')
      and not has_function_privilege('anon', 'public.sync_outstanding_tasks()', 'EXECUTE')
      and not has_function_privilege('anon', 'public._sync_outstanding_tasks_for_org(uuid)', 'EXECUTE')
      and not has_function_privilege('public', 'public.sync_outstanding_tasks()', 'EXECUTE')
      and not has_function_privilege('public', 'public._sync_outstanding_tasks_for_org(uuid)', 'EXECUTE')
      and not has_function_privilege('public', 'public.refresh_outstanding_tasks()', 'EXECUTE')
    into v_ok;
  res := res || E'\ntest9 anon/PUBLIC cannot execute refresh/sync/internal functions (expect true): ' || v_ok;

  -- authenticated SHOULD be able to execute refresh_outstanding_tasks (its
  -- own is_master() guard decides who succeeds), but must NOT have
  -- execute on the cron entry point or the internal per-org function.
  select
      has_function_privilege('authenticated', 'public.refresh_outstanding_tasks()', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.sync_outstanding_tasks()', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public._sync_outstanding_tasks_for_org(uuid)', 'EXECUTE')
    into v_ok;
  res := res || E'\ntest10 authenticated has refresh_outstanding_tasks only, not the cron/internal functions (expect true): ' || v_ok;

  -- ── the new unique index is actually enforced (impersonating master so
  -- the customer_outstanding task-ref guard trigger doesn't reject this
  -- insert for an unrelated reason before the unique index even gets a
  -- chance to) ────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into public.tasks (org_id, assignee_id, assigned_by, title, due_date, source, ref_type, ref_id)
      values (v_org, v_master, v_master, '__TEST_sot_dup', current_date, 'manual', 'customer_outstanding', v_cust_b);
    res := res || E'\ntest11 a second open customer_outstanding task for the same customer: INSERT SUCCEEDED (bad)';
  exception when unique_violation then
    res := res || E'\ntest11 a second open customer_outstanding task for the same customer: correctly rejected by the unique index (good)';
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

  -- ── cron job registered exactly once ───────────────────────────────────
  select count(*) into v_count from cron.job where jobname = 'sync-outstanding-tasks';
  res := res || E'\ntest12 sync-outstanding-tasks cron job registered exactly once (expect 1): ' || v_count;

  -- ── is_test_customer exclusion (matches report_customer_outstanding's
  -- existing exclusion of the one permanently-kept test customer) ────────
  declare
    v_cust_flagged uuid;
    v_inv_flagged uuid;
  begin
    insert into public.customers (org_id, name, is_test) values (v_org, '__TEST_sot_flagged', true) returning id into v_cust_flagged;
    insert into public.invoices (org_id, customer_id, type, subtotal, discount, gst, total, payment_status, amount_paid, created_at)
      values (v_org, v_cust_flagged, 'product', 500, 0, 0, 500, 'due', 0, now() - interval '30 days')
      returning id into v_inv_flagged;

    perform set_config('request.jwt.claims', json_build_object('sub', v_master, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.refresh_outstanding_tasks();
    execute 'reset role';
  perform set_config('request.jwt.claims', '', true);

    select count(*) = 0 into v_ok from public.tasks
      where org_id = v_org and ref_type = 'customer_outstanding' and ref_id = v_cust_flagged and status = 'open';
    res := res || E'\ntest13 is_test=true customer never gets a task even when well above threshold (expect true): ' || v_ok;
  end;

  raise exception E'RESULTS:%', res;
end
$sync_outstanding_test$;
$testbody$;
begin
  -- 0. ORG CHECK
  select md5(o.id::text || '|' || o.name) into v_actual_org_fingerprint
  from public.organizations o
  where o.name not like '\_\_TEST%' escape '\'
  order by o.created_at asc
  limit 1;

  if v_actual_org_fingerprint is distinct from v_expected_org_fingerprint then
    raise exception 'REHEARSAL_REFUSED: organisation fingerprint mismatch';
  end if;

  -- 1. LOCK
  perform set_config('lock_timeout', '5s', true);

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'))::int;

  -- 2. GATE -- this project's lowered convention (11:00 IST), not the older 18:00.
  if v_ist_hour < 11 then
    raise exception 'REHEARSAL_REFUSED: this rehearsal only runs after 11:00 IST (current IST hour=%)', v_ist_hour;
  end if;

  -- 3. PIN
  v_actual_migration_hash := encode(sha256(convert_to(replace(v_embedded_migration, E'\r', ''), 'UTF8')), 'hex');
  v_actual_test_hash := encode(sha256(convert_to(replace(v_embedded_test, E'\r', ''), 'UTF8')), 'hex');

  if v_actual_migration_hash is distinct from v_expected_migration_hash then
    raise exception 'REHEARSAL_REFUSED: embedded MIGRATION text does not match its pinned sha256 (expected %, got %)',
      v_expected_migration_hash, v_actual_migration_hash;
  end if;

  if v_actual_test_hash is distinct from v_expected_test_hash then
    raise exception 'REHEARSAL_REFUSED: embedded TEST text does not match its pinned sha256 (expected %, got %)',
      v_expected_test_hash, v_actual_test_hash;
  end if;

  res := res || E'\nok   ORG CHECK passed, GATE passed: IST hour=' || v_ist_hour || E', both embedded-text sha256 hashes verified';

  -- Real-organisation fingerprint BEFORE -- every real (non __TEST_) row across the
  -- tables this payroll-fixes release touches, reduced to one digest.
  -- Deliberately references only columns that exist BEFORE any of the three
  -- payroll-fixes migrations run (id/net/amount/owner_id are all pre-existing) --
  -- each migration adds different new columns, so a fingerprint that depended on
  -- one of them would fail at the BEFORE snapshot for whichever rehearsal runs
  -- first. Identity + core value is enough to prove no real row was touched.
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_before
  from (
    select 'inv:' || i.id::text || ':' || i.amount_paid::text || ':' || i.payment_status::text as x
    from public.invoices i
    join public.customers c on c.id = i.customer_id
    where c.name not like '\_\_TEST\_%' escape '\' and not coalesce(c.is_test, false)
    union all
    select 'task:' || t.id::text || ':' || t.status::text || ':' || coalesce(t.title, '-')
    from public.tasks t
    join public.customers c2 on c2.id = t.ref_id
    where t.ref_type = 'customer_outstanding'
      and c2.name not like '\_\_TEST\_%' escape '\' and not coalesce(c2.is_test, false)
    union all
    select 'cust:' || c3.id::text || ':' || c3.name
    from public.customers c3
    where c3.name not like '\_\_TEST\_%' escape '\'
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint BEFORE = ' || v_fp_before;

  -- 4. RUN
  execute replace(v_embedded_migration, E'\r', '');
  res := res || E'\nok   migration applied inside this still-open transaction';

  begin
    execute replace(v_embedded_test, E'\r', '');
    v_inner_result := 'FAIL embedded test returned without raising -- it must always end in RAISE EXCEPTION E''RESULTS:%''';
  exception when others then
    v_inner_result := sqlerrm;
  end;
  res := res || E'\n--- embedded test output ---\n' || coalesce(v_inner_result, '(no result captured)') || E'\n--- end embedded test output ---';

  -- 5. PROVE
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_fp_after
  from (
    select 'inv:' || i.id::text || ':' || i.amount_paid::text || ':' || i.payment_status::text as x
    from public.invoices i
    join public.customers c on c.id = i.customer_id
    where c.name not like '\_\_TEST\_%' escape '\' and not coalesce(c.is_test, false)
    union all
    select 'task:' || t.id::text || ':' || t.status::text || ':' || coalesce(t.title, '-')
    from public.tasks t
    join public.customers c2 on c2.id = t.ref_id
    where t.ref_type = 'customer_outstanding'
      and c2.name not like '\_\_TEST\_%' escape '\' and not coalesce(c2.is_test, false)
    union all
    select 'cust:' || c3.id::text || ':' || c3.name
    from public.customers c3
    where c3.name not like '\_\_TEST\_%' escape '\'
  ) real_rows;
  res := res || E'\nINFO real-row fingerprint AFTER  = ' || v_fp_after;
  res := res || E'\n' || case when v_fp_after = v_fp_before
                          then 'ok   real-organisation fingerprint unchanged -- this rehearsal mutated no real data'
                          else 'FAIL real-organisation fingerprint CHANGED -- investigate before trusting anything above' end;

  raise exception E'RESULTS:%', res;
end
$rehearsal$;
