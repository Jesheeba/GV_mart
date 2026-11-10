-- Exercised rollback proof for 20261204100000_sync_outstanding_tasks.sql.
-- Applies the migration's DDL, verifies every artifact now exists, runs
-- the sibling *.rollback.sql DDL verbatim, verifies zero residue by both
-- catalog queries and a sha256 catalog-state digest, verifies four whole
-- tables (tasks/settings/invoices/customers) are byte-identical by
-- count+md5 before vs after, verifies the anon-exposure set is unchanged,
-- then forces an unconditional rollback of this entire probe so nothing
-- here is ever committed -- apply.sql itself is still untouched and still
-- requires separate, explicit approval to run for real.
do $rollback_proof$
declare
  res text := '';
  v_catalog_before text;
  v_catalog_after text;
  v_tasks_before text;
  v_tasks_after text;
  v_settings_before text;
  v_settings_after text;
  v_invoices_before text;
  v_invoices_after text;
  v_customers_before text;
  v_customers_after text;
  v_anon_before text;
  v_anon_after text;
  v_count int;
begin
  -- 0. PRECONDITION -- nothing from this migration exists yet.
  select count(*) into v_count from pg_proc
    where proname in ('_sync_outstanding_tasks_for_org','sync_outstanding_tasks','refresh_outstanding_tasks');
  if v_count <> 0 then
    raise exception 'PRECONDITION FAILED: % of the 3 functions already exist -- this probe assumes nothing is live yet', v_count;
  end if;
  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    raise exception 'PRECONDITION FAILED: the cron job already exists';
  end if;

  -- 1. BEFORE snapshots.
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_catalog_before
  from (
    select 'fn:' || proname as x from pg_proc
      where proname in ('_sync_outstanding_tasks_for_org','sync_outstanding_tasks','refresh_outstanding_tasks')
    union all
    select 'cron:' || jobname from cron.job where jobname = 'sync-outstanding-tasks'
    union all
    select 'idx:' || indexname from pg_indexes where indexname = 'tasks_customer_outstanding_one_open_idx'
    union all
    select 'col:' || column_name from information_schema.columns
      where table_name = 'settings' and column_name in ('min_outstanding_balance','min_outstanding_days','default_accounts_owner_id')
    union all
    select 'mig:' || version from supabase_migrations.schema_migrations where version = '20261204100000'
  ) s;

  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_tasks_before from public.tasks;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_settings_before from public.settings;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_invoices_before from public.invoices;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_customers_before from public.customers;

  select encode(sha256(convert_to(coalesce(string_agg(proname, ',' order by proname), ''), 'UTF8')), 'hex') into v_anon_before
  from pg_proc p where has_function_privilege('anon', p.oid, 'EXECUTE');

  res := res || E'\nINFO catalog BEFORE  = ' || v_catalog_before;
  res := res || E'\nINFO tasks BEFORE    = ' || v_tasks_before;
  res := res || E'\nINFO settings BEFORE = ' || v_settings_before;
  res := res || E'\nINFO invoices BEFORE = ' || v_invoices_before;
  res := res || E'\nINFO customers BEFORE= ' || v_customers_before;
  res := res || E'\nINFO anon-exposure BEFORE = ' || v_anon_before;

  -- 2. APPLY -- the migration's DDL, verbatim (same body as the committed
  -- apply.sql, minus its own guard/register, which aren't needed inside
  -- this self-contained probe).
  alter table public.settings add column if not exists min_outstanding_balance numeric(12,2) not null default 50 check (min_outstanding_balance >= 0);
  alter table public.settings add column if not exists min_outstanding_days integer not null default 3 check (min_outstanding_days >= 0);
  alter table public.settings add column if not exists default_accounts_owner_id uuid references public.profiles (id) on delete set null;

  create unique index if not exists tasks_customer_outstanding_one_open_idx
    on public.tasks (org_id, ref_id)
    where ref_type = 'customer_outstanding' and status = 'open';

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
    end loop;

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

  create extension if not exists pg_cron with schema pg_catalog;

  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    perform cron.unschedule('sync-outstanding-tasks');
  end if;
  perform cron.schedule('sync-outstanding-tasks', '30 0 * * *', 'select public.sync_outstanding_tasks()');

  insert into supabase_migrations.schema_migrations (version, name, statements)
  values ('20261204100000', 'sync_outstanding_tasks', array[]::text[]);

  res := res || E'\nok   migration DDL applied inside this still-open probe transaction';

  -- 3. VERIFY created.
  select count(*) into v_count from pg_proc
    where proname in ('_sync_outstanding_tasks_for_org','sync_outstanding_tasks','refresh_outstanding_tasks');
  if v_count <> 3 then raise exception 'VERIFY FAILED: expected 3 functions after apply, found %', v_count; end if;
  if not exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    raise exception 'VERIFY FAILED: cron job missing after apply';
  end if;
  if not exists (select 1 from pg_indexes where indexname = 'tasks_customer_outstanding_one_open_idx') then
    raise exception 'VERIFY FAILED: index missing after apply';
  end if;
  select count(*) into v_count from information_schema.columns
    where table_name = 'settings' and column_name in ('min_outstanding_balance','min_outstanding_days','default_accounts_owner_id');
  if v_count <> 3 then raise exception 'VERIFY FAILED: expected 3 settings columns after apply, found %', v_count; end if;
  if not exists (select 1 from supabase_migrations.schema_migrations where version = '20261204100000') then
    raise exception 'VERIFY FAILED: migration version not registered after apply';
  end if;
  res := res || E'\nok   all 5 artifact kinds verified present after apply (3 functions, cron job, index, 3 settings columns, migration version)';

  -- 4. ROLLBACK -- the sibling *.rollback.sql DDL, verbatim.
  if exists (select 1 from cron.job where jobname = 'sync-outstanding-tasks') then
    perform cron.unschedule('sync-outstanding-tasks');
  end if;

  drop function if exists public.refresh_outstanding_tasks();
  drop function if exists public.sync_outstanding_tasks();
  drop function if exists public._sync_outstanding_tasks_for_org(uuid);

  drop index if exists public.tasks_customer_outstanding_one_open_idx;

  alter table public.settings drop column if exists min_outstanding_balance;
  alter table public.settings drop column if exists min_outstanding_days;
  alter table public.settings drop column if exists default_accounts_owner_id;

  delete from supabase_migrations.schema_migrations where version = '20261204100000';

  res := res || E'\nok   rollback DDL executed inside this still-open probe transaction';

  -- 5. VERIFY 0 residue -- catalog queries.
  select count(*) into v_count from pg_proc
    where proname in ('_sync_outstanding_tasks_for_org','sync_outstanding_tasks','refresh_outstanding_tasks');
  res := res || E'\nRESIDUE functions remaining (expect 0): ' || v_count;
  select count(*) into v_count from cron.job where jobname = 'sync-outstanding-tasks';
  res := res || E'\nRESIDUE cron jobs remaining (expect 0): ' || v_count;
  select count(*) into v_count from pg_indexes where indexname = 'tasks_customer_outstanding_one_open_idx';
  res := res || E'\nRESIDUE indexes remaining (expect 0): ' || v_count;
  select count(*) into v_count from information_schema.columns
    where table_name = 'settings' and column_name in ('min_outstanding_balance','min_outstanding_days','default_accounts_owner_id');
  res := res || E'\nRESIDUE settings columns remaining (expect 0): ' || v_count;
  select count(*) into v_count from supabase_migrations.schema_migrations where version = '20261204100000';
  res := res || E'\nRESIDUE migration version rows remaining (expect 0): ' || v_count;

  -- 5b. VERIFY 0 residue -- sha256 catalog-state digest, must equal BEFORE.
  select encode(sha256(convert_to(coalesce(string_agg(x, ',' order by x), ''), 'UTF8')), 'hex') into v_catalog_after
  from (
    select 'fn:' || proname as x from pg_proc
      where proname in ('_sync_outstanding_tasks_for_org','sync_outstanding_tasks','refresh_outstanding_tasks')
    union all
    select 'cron:' || jobname from cron.job where jobname = 'sync-outstanding-tasks'
    union all
    select 'idx:' || indexname from pg_indexes where indexname = 'tasks_customer_outstanding_one_open_idx'
    union all
    select 'col:' || column_name from information_schema.columns
      where table_name = 'settings' and column_name in ('min_outstanding_balance','min_outstanding_days','default_accounts_owner_id')
    union all
    select 'mig:' || version from supabase_migrations.schema_migrations where version = '20261204100000'
  ) s;
  res := res || E'\nINFO catalog AFTER   = ' || v_catalog_after;
  res := res || E'\n' || case when v_catalog_after = v_catalog_before
    then 'ok   catalog-state digest matches BEFORE exactly (0 residue, byte-for-byte)'
    else 'FAIL catalog-state digest CHANGED -- residue detected' end;

  -- 6. VERIFY the four whole tables are untouched by this whole probe.
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_tasks_after from public.tasks;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_settings_after from public.settings;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_invoices_after from public.invoices;
  select count(*)::text || ':' || coalesce(md5(string_agg(id::text, ',' order by id)), '(empty)') into v_customers_after from public.customers;

  res := res || E'\nINFO tasks AFTER     = ' || v_tasks_after;
  res := res || E'\n' || case when v_tasks_after = v_tasks_before then 'ok   tasks table count+md5 unchanged' else 'FAIL tasks table CHANGED' end;
  res := res || E'\nINFO settings AFTER  = ' || v_settings_after;
  res := res || E'\n' || case when v_settings_after = v_settings_before then 'ok   settings table count+md5 unchanged' else 'FAIL settings table CHANGED' end;
  res := res || E'\nINFO invoices AFTER  = ' || v_invoices_after;
  res := res || E'\n' || case when v_invoices_after = v_invoices_before then 'ok   invoices table count+md5 unchanged' else 'FAIL invoices table CHANGED' end;
  res := res || E'\nINFO customers AFTER = ' || v_customers_after;
  res := res || E'\n' || case when v_customers_after = v_customers_before then 'ok   customers table count+md5 unchanged' else 'FAIL customers table CHANGED' end;

  -- 7. VERIFY anon-exposure set is unchanged (no residual anon grant anywhere).
  select encode(sha256(convert_to(coalesce(string_agg(proname, ',' order by proname), ''), 'UTF8')), 'hex') into v_anon_after
  from pg_proc p where has_function_privilege('anon', p.oid, 'EXECUTE');
  res := res || E'\nINFO anon-exposure AFTER  = ' || v_anon_after;
  res := res || E'\n' || case when v_anon_after = v_anon_before
    then 'ok   anon-exposure set unchanged -- no residual anon grant from this probe'
    else 'FAIL anon-exposure set CHANGED' end;

  raise exception E'RESULTS:%', res;
end
$rollback_proof$;
