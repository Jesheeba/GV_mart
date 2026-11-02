-- GO APPLY script for the Drop 1 SECURITY FIX migration (20261125100800), applied on top of
-- the already-live Drop 1 (versions 20261125100000-20261125100700). WRITTEN ONLY -- never
-- executed by the agent that produced this file until explicitly asked to run it live.
--
-- Found by an independent security review of the integrated branch plus a live RLS-impersonation
-- probe on test data: multiple SECURITY DEFINER RPCs were missing org-scoping/authorization
-- checks (cross-tenant read/write), and the technician RLS policies on
-- customer_installed_products/customer_part_schedules/part_replacement_history silently matched
-- zero rows for a real technician with a real assigned customer. See the migration file's own
-- header for the full list and the fix applied to each.

drop table if exists pg_temp.lifecycle_security_fix_apply_status;
create temp table lifecycle_security_fix_apply_status (
  version_registered boolean,
  org_fingerprint_before text,
  org_fingerprint_after text,
  org_fingerprint_unchanged boolean,
  newly_leaked_functions text[],
  applied_at timestamptz
);

do $apply$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before text;
  v_org_fingerprint_after text;
  v_leaked_before text[];
  v_leaked_after text[];
  v_newly_leaked text[];
  v_migration_text text := $mig$-- Product Lifecycle & Automated Service Reminder System — Drop 1, SECURITY FIX migration,
-- applied after the original 8 migrations (which were already live). Found by an independent
-- security review of the integrated branch plus a live RLS-impersonation probe on test data.
--
-- Fix 1 — RLS: a technician's own view into customer_installed_products/customer_part_schedules/
-- part_replacement_history was wired through service_visits -> service_tickets directly in the
-- policy's own USING clause. That subquery runs under the CALLER's privileges (RLS policies are
-- not SECURITY DEFINER), and service_tickets' own RLS only grants a technician visibility via an
-- appointments row (service_tickets_select_own_technician /
-- service_tickets_select_customer_history_technician, both in
-- 20260701091300_rls.sql / 20260723120000_technician_customer_history_rls.sql), not via
-- service_visits alone -- so the join silently matched zero rows for a real technician with a
-- real visit, proven live: a probe technician with an actual service_visits row for their
-- customer could not see that customer's installed product or part schedule at all. Fixed by
-- reusing the project's own existing, already-correct, SECURITY DEFINER helper
-- `is_technician_customer(customer_id)` (defined in
-- 20260723120000_technician_customer_history_rls.sql) instead of re-deriving the same check by
-- hand — same house pattern service_tickets' own policy already uses.
--
-- Fix 2 — RPC authorization gaps (the review's High-severity findings): every one of
-- create_installed_product, log_installed_products_for_invoice, get_customer_due_parts,
-- correct_installation_date, apply_updated_schedule, apply_updated_schedule_preview and
-- record_part_replacement is SECURITY DEFINER (bypasses RLS internally by design) but several
-- never re-derived the caller's authority or organisation themselves, so a logged-in but
-- unrelated user, or a staff member of a DIFFERENT org, could call them directly with an
-- arbitrary target id and read or write another tenant's data. Every function below now checks,
-- when called by an authenticated session (auth.uid() is not null -- the one-time backfill
-- migration and the cron job call some of these as service_role/superuser with no auth
-- context, and are exempt by design, same as before):
--   * the target row's organisation matches public.current_org_id(), and
--   * the caller is authorized for that specific customer/product (is_staff(), is_master(),
--     current_customer_id(), or is_technician_customer(), as appropriate to each function).

-- ── RLS fix ──────────────────────────────────────────────────────────────
drop policy if exists customer_installed_products_select_technician on public.customer_installed_products;
create policy customer_installed_products_select_technician on public.customer_installed_products
  for select using (public.is_technician_customer(customer_id));

drop policy if exists customer_part_schedules_select_technician on public.customer_part_schedules;
create policy customer_part_schedules_select_technician on public.customer_part_schedules
  for select using (
    exists (
      select 1 from public.customer_installed_products cip
      where cip.id = customer_part_schedules.installed_product_id
        and public.is_technician_customer(cip.customer_id)
    )
  );

drop policy if exists part_replacement_history_select_technician on public.part_replacement_history;
create policy part_replacement_history_select_technician on public.part_replacement_history
  for select using (
    recorded_by = auth.uid()
    or exists (
      select 1 from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where cps.id = part_replacement_history.customer_part_schedule_id
        and public.is_technician_customer(cip.customer_id)
    )
  );

-- ── create_installed_product: org + authorization check ────────────────
create or replace function public.create_installed_product(
  p_customer_id uuid,
  p_product_id uuid,
  p_installation_date date,
  p_visit_id uuid default null,
  p_is_backfilled boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org_id uuid;
  v_config record;
  v_installed_id uuid;
  v_spare record;
begin
  select org_id into v_org_id from public.customers where id = p_customer_id;
  if v_org_id is null then
    raise exception 'create_installed_product: customer % not found', p_customer_id;
  end if;

  if auth.uid() is not null then
    if public.current_org_id() is distinct from v_org_id then
      raise exception 'create_installed_product: not authorized for this customer''s organisation';
    end if;
    if not (public.is_staff() or public.is_technician_customer(p_customer_id)) then
      raise exception 'create_installed_product: not authorized for this customer';
    end if;
  end if;

  select * into v_config from public.product_lifecycle_configs
  where product_id = p_product_id and is_active;

  insert into public.customer_installed_products (
    org_id, customer_id, product_id, installation_date, installation_date_confirmed,
    installation_visit_id, lifecycle_config_id, lifetime_expiry_date, is_backfilled
  ) values (
    v_org_id, p_customer_id, p_product_id, p_installation_date, not p_is_backfilled,
    p_visit_id, v_config.id,
    case when v_config.id is not null
      then public._lifecycle_add_interval(p_installation_date, v_config.lifetime_value, v_config.lifetime_unit)
      else null end,
    p_is_backfilled
  ) returning id into v_installed_id;

  for v_spare in
    select * from public.product_spare_schedules
    where product_id = p_product_id and is_active
  loop
    insert into public.customer_part_schedules (
      org_id, installed_product_id, product_spare_schedule_id, label,
      interval_value, interval_unit, next_due_date
    ) values (
      v_org_id, v_installed_id, v_spare.id, v_spare.label,
      v_spare.interval_value, v_spare.interval_unit,
      public._lifecycle_add_interval(p_installation_date, v_spare.interval_value, v_spare.interval_unit)
    )
    on conflict (installed_product_id, product_spare_schedule_id) do nothing;
  end loop;

  return v_installed_id;
end;
$$;

-- ── log_installed_products_for_invoice: org + authorization check ──────
create or replace function public.log_installed_products_for_invoice(
  p_customer_id uuid,
  p_visit_id uuid,
  p_installations jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item record;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_customer_org uuid;
begin
  select org_id into v_customer_org from public.customers where id = p_customer_id;
  if v_customer_org is null then
    raise exception 'log_installed_products_for_invoice: customer % not found', p_customer_id;
  end if;
  if auth.uid() is not null then
    if public.current_org_id() is distinct from v_customer_org then
      raise exception 'log_installed_products_for_invoice: not authorized for this customer''s organisation';
    end if;
    if not (public.is_staff() or public.is_technician_customer(p_customer_id)) then
      raise exception 'log_installed_products_for_invoice: not authorized for this customer';
    end if;
  end if;

  for v_item in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
  loop
    perform public.create_installed_product(p_customer_id, v_item.product_id, v_today, p_visit_id, false);
  end loop;
end;
$$;

-- ── get_customer_due_parts: org + authorization check ───────────────────
create or replace function public.get_customer_due_parts(p_customer_id uuid)
returns setof public.customer_part_schedules
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_customer_org uuid;
begin
  select org_id into v_customer_org from public.customers where id = p_customer_id;
  if v_customer_org is null then
    return;
  end if;
  if auth.uid() is not null then
    -- coalesce(..., false) matters: current_customer_id() = p_customer_id yields NULL (not
    -- false) for a non-customer caller, and plpgsql's IF treats a NULL condition as false --
    -- without the coalesce, "if not (A or NULL or C)" silently never raises.
    if not coalesce(
      (public.current_org_id() = v_customer_org and public.is_staff())
      or public.current_customer_id() = p_customer_id
      or public.is_technician_customer(p_customer_id),
      false
    ) then
      raise exception 'get_customer_due_parts: not authorized for this customer';
    end if;
  end if;
  return query
    select cps.* from public.customer_part_schedules cps
    join public.customer_installed_products cip on cip.id = cps.installed_product_id
    where cip.customer_id = p_customer_id
      and cps.status in ('due_soon', 'due', 'overdue')
    order by cps.next_due_date;
end;
$$;

-- ── correct_installation_date: org check added (role check already existed) ──
create or replace function public.correct_installation_date(
  p_installed_product_id uuid,
  p_new_installation_date date
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_row public.customer_installed_products;
begin
  if not public.is_master() then
    raise exception 'correct_installation_date: master only';
  end if;

  select * into v_row from public.customer_installed_products where id = p_installed_product_id;
  if v_row.id is null then
    raise exception 'correct_installation_date: installed product % not found', p_installed_product_id;
  end if;
  if v_row.org_id is distinct from public.current_org_id() then
    raise exception 'correct_installation_date: not authorized for this organisation';
  end if;

  update public.customer_installed_products
  set installation_date = p_new_installation_date,
      installation_date_confirmed = true,
      lifetime_expiry_date = case when lifecycle_config_id is not null
        then public._lifecycle_add_interval(
          p_new_installation_date,
          (select lifetime_value from public.product_lifecycle_configs where id = v_row.lifecycle_config_id),
          (select lifetime_unit from public.product_lifecycle_configs where id = v_row.lifecycle_config_id))
        else lifetime_expiry_date end
  where id = p_installed_product_id;

  update public.customer_part_schedules
  set next_due_date = public._lifecycle_add_interval(p_new_installation_date, interval_value, interval_unit)
  where installed_product_id = p_installed_product_id
    and last_replaced_date is null;
end;
$$;

-- ── apply_updated_schedule_preview: NO check existed at all -- added master-only + org scope ──
create or replace function public.apply_updated_schedule_preview(p_product_id uuid)
returns table (installed_product_id uuid, customer_id uuid, parts_to_add integer)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.is_master() then
    raise exception 'apply_updated_schedule_preview: master only';
  end if;
  if not exists (select 1 from public.products p where p.id = p_product_id and p.org_id = public.current_org_id()) then
    raise exception 'apply_updated_schedule_preview: not authorized for this product';
  end if;

  return query
  select cip.id, cip.customer_id, count(pss.id)::integer
  from public.customer_installed_products cip
  join public.product_spare_schedules pss
    on pss.product_id = p_product_id and pss.is_active
  where cip.product_id = p_product_id
    and cip.org_id = public.current_org_id()
    and cip.status = 'active'
    and not exists (
      select 1 from public.customer_part_schedules cps
      where cps.installed_product_id = cip.id and cps.product_spare_schedule_id = pss.id
    )
  group by cip.id, cip.customer_id
  having count(pss.id) > 0;
end;
$$;

-- ── apply_updated_schedule: org scope added to the product check (role check already existed) ──
create or replace function public.apply_updated_schedule(p_product_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_cip record;
  v_pss record;
  v_applied integer := 0;
begin
  if not public.is_master() then
    raise exception 'apply_updated_schedule: master only';
  end if;
  if not exists (select 1 from public.products p where p.id = p_product_id and p.org_id = public.current_org_id()) then
    raise exception 'apply_updated_schedule: not authorized for this product';
  end if;

  for v_cip in
    select id, org_id, installation_date from public.customer_installed_products
    where product_id = p_product_id and status = 'active' and org_id = public.current_org_id()
  loop
    for v_pss in
      select * from public.product_spare_schedules where product_id = p_product_id and is_active
    loop
      insert into public.customer_part_schedules (
        org_id, installed_product_id, product_spare_schedule_id, label,
        interval_value, interval_unit, next_due_date
      ) values (
        v_cip.org_id, v_cip.id, v_pss.id, v_pss.label, v_pss.interval_value, v_pss.interval_unit,
        public._lifecycle_add_interval(v_cip.installation_date, v_pss.interval_value, v_pss.interval_unit)
      )
      on conflict (installed_product_id, product_spare_schedule_id) do nothing;
      if found then
        v_applied := v_applied + 1;
      end if;
    end loop;
  end loop;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  select public.current_org_id(), auth.uid(), 'APPLY_UPDATED_SCHEDULE', 'product_spare_schedules', p_product_id,
         null, jsonb_build_object('product_id', p_product_id, 'parts_added', v_applied);

  return v_applied;
end;
$$;

-- ── record_part_replacement: org check added to the existing staff/technician check ──
create or replace function public.record_part_replacement(
  p_schedule_id uuid,
  p_replaced_date date,
  p_spare_used_id uuid default null,
  p_visit_id uuid default null,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_schedule public.customer_part_schedules;
  v_customer_id uuid;
  v_allowed boolean;
begin
  if p_replaced_date > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'record_part_replacement: replaced date cannot be in the future';
  end if;

  select cps.* into v_schedule from public.customer_part_schedules cps where cps.id = p_schedule_id;
  if v_schedule.id is null then
    raise exception 'record_part_replacement: schedule % not found', p_schedule_id;
  end if;

  if auth.uid() is not null and v_schedule.org_id is distinct from public.current_org_id() then
    raise exception 'record_part_replacement: not authorized for this organisation';
  end if;

  select cip.customer_id into v_customer_id
  from public.customer_installed_products cip where cip.id = v_schedule.installed_product_id;

  v_allowed := public.is_staff() or public.is_technician_customer(v_customer_id);
  if not v_allowed then
    raise exception 'record_part_replacement: not authorized for this customer''s schedule';
  end if;

  insert into public.part_replacement_history (
    org_id, customer_part_schedule_id, replaced_date, previous_due_date, next_due_date,
    spare_used_id, recorded_by, visit_id, note
  ) values (
    v_schedule.org_id, p_schedule_id, p_replaced_date, v_schedule.next_due_date,
    public._lifecycle_add_interval(p_replaced_date, v_schedule.interval_value, v_schedule.interval_unit),
    p_spare_used_id, auth.uid(), p_visit_id, p_note
  );

  update public.customer_part_schedules
  set last_replaced_date = p_replaced_date,
      next_due_date = public._lifecycle_add_interval(p_replaced_date, interval_value, interval_unit),
      status = 'pending'
  where id = p_schedule_id;
end;
$$;

-- ── belt-and-suspenders revoke consistency (Low/Note finding) ──────────
revoke all on function public.generate_lifecycle_reminders(timestamptz) from public, anon, authenticated;

-- ── re-sweep anon/public exposure on every replaced function, same as migration 100700 ──
revoke all on function
  public.create_installed_product(uuid, uuid, date, uuid, boolean),
  public.log_installed_products_for_invoice(uuid, uuid, jsonb),
  public.get_customer_due_parts(uuid),
  public.correct_installation_date(uuid, date),
  public.apply_updated_schedule_preview(uuid),
  public.apply_updated_schedule(uuid),
  public.record_part_replacement(uuid, date, uuid, uuid, text)
from public, anon;
grant execute on function
  public.create_installed_product(uuid, uuid, date, uuid, boolean),
  public.log_installed_products_for_invoice(uuid, uuid, jsonb),
  public.get_customer_due_parts(uuid),
  public.correct_installation_date(uuid, date),
  public.apply_updated_schedule_preview(uuid),
  public.apply_updated_schedule(uuid),
  public.record_part_replacement(uuid, date, uuid, uuid, text)
to authenticated;
$mig$;
begin
  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_before
  from public.organizations o where o.name not like '%__TEST_%' order by o.created_at asc limit 1;
  if v_org_fingerprint_before is distinct from v_expected_org_fingerprint then
    raise exception 'ORG CHECK: fingerprint mismatch (expected %, got %) -- refusing', v_expected_org_fingerprint, v_org_fingerprint_before;
  end if;

  set lock_timeout = '5s';

  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'));
  if v_ist_hour < 11 then
    raise exception 'GATE: refusing before 11:00 IST (current IST hour %)', v_ist_hour;
  end if;

  if exists (select 1 from supabase_migrations.schema_migrations where version = '20261125100800') then
    raise exception 'ALREADY-REGISTERED: 20261125100800 is already applied -- refusing';
  end if;

  select coalesce(array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text), array[]::text[])
    into v_leaked_before
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');

  execute v_migration_text;

  insert into supabase_migrations.schema_migrations (version) values ('20261125100800') on conflict do nothing;

  select coalesce(array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text), array[]::text[])
    into v_leaked_after
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');
  select coalesce(array_agg(x), array[]::text[]) into v_newly_leaked
  from unnest(v_leaked_after) x where x <> all(v_leaked_before);
  if array_length(v_newly_leaked, 1) > 0 then
    raise exception 'POST-APPLY: new anon-executable function(s) detected: %', v_newly_leaked;
  end if;

  select md5(o.id::text || '|' || o.name) into v_org_fingerprint_after
  from public.organizations o where o.name not like '%__TEST_%' order by o.created_at asc limit 1;
  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'POST-APPLY: real organisation fingerprint changed (% -> %)', v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  insert into pg_temp.lifecycle_security_fix_apply_status
  values (true, v_org_fingerprint_before, v_org_fingerprint_after, true, v_newly_leaked, now());
end;
$apply$;

select * from pg_temp.lifecycle_security_fix_apply_status;
