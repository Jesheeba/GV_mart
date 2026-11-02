-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 4/8.
-- Core RPCs. PostgreSQL's own date+interval arithmetic already clamps an
-- overflowing day to the last day of the target month (documented behaviour),
-- so no bespoke month-end-clamp helper is needed — just convert
-- months-or-years to a plain "N months" interval.

create or replace function public._lifecycle_add_interval(p_base date, p_value integer, p_unit text)
returns date
language sql immutable
set search_path to 'public'
as $$
  select (p_base + ((case when p_unit = 'years' then p_value * 12 else p_value end) || ' months')::interval)::date
$$;

revoke all on function public._lifecycle_add_interval(date, integer, text) from public, anon;

-- ── create_installed_product ────────────────────────────────────────────
-- Called from create_service_invoice's installation loop on every future
-- technician installation, and by the one-time backfill migration.
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

revoke all on function public.create_installed_product(uuid, uuid, date, uuid, boolean) from public, anon;
grant execute on function public.create_installed_product(uuid, uuid, date, uuid, boolean) to authenticated;

-- ── correct_installation_date ───────────────────────────────────────────
-- Amendment 1: the Master can correct the real installation date per
-- installed product. Parts never yet replaced are rescheduled from the new
-- date; parts already replaced keep their actual-replacement-anchored
-- schedule untouched (a later install-date correction must not retroactively
-- move a due date that's already anchored to a real event).
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
  -- ^ this UPDATE is itself the audit record (audit_customer_installed_products
  -- trigger logs before/after, actor, timestamp — see migration 100100).

  update public.customer_part_schedules
  set next_due_date = public._lifecycle_add_interval(p_new_installation_date, interval_value, interval_unit)
  where installed_product_id = p_installed_product_id
    and last_replaced_date is null;
end;
$$;

revoke all on function public.correct_installation_date(uuid, date) from public, anon;
grant execute on function public.correct_installation_date(uuid, date) to authenticated;

-- ── apply_updated_schedule_preview / apply_updated_schedule ─────────────
-- Amendment 3: editing a product's spare schedule never retroactively
-- changes an already-anchored customer_part_schedules row. This is the
-- Master-only opt-in action that ADDS a schedule row for any
-- product_spare_schedules entry a given installed product doesn't have yet
-- (e.g. a part added to the Masters repeater after that unit was installed).
-- It never edits or deletes an existing customer_part_schedules row.
create or replace function public.apply_updated_schedule_preview(p_product_id uuid)
returns table (installed_product_id uuid, customer_id uuid, parts_to_add integer)
language sql
security definer
set search_path to 'public'
as $$
  select cip.id, cip.customer_id, count(pss.id)::integer
  from public.customer_installed_products cip
  join public.product_spare_schedules pss
    on pss.product_id = p_product_id and pss.is_active
  where cip.product_id = p_product_id
    and cip.status = 'active'
    and not exists (
      select 1 from public.customer_part_schedules cps
      where cps.installed_product_id = cip.id and cps.product_spare_schedule_id = pss.id
    )
  group by cip.id, cip.customer_id
  having count(pss.id) > 0
$$;

revoke all on function public.apply_updated_schedule_preview(uuid) from public, anon;
grant execute on function public.apply_updated_schedule_preview(uuid) to authenticated;

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

  for v_cip in
    select id, org_id, installation_date from public.customer_installed_products
    where product_id = p_product_id and status = 'active'
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

  -- Audited explicitly here (beyond the per-row insert trigger) so the
  -- "apply updated schedule" ACTION itself, not just its row effects, has one
  -- summary audit_log entry a Master can find by action text.
  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  select public.current_org_id(), auth.uid(), 'APPLY_UPDATED_SCHEDULE', 'product_spare_schedules', p_product_id,
         null, jsonb_build_object('product_id', p_product_id, 'parts_added', v_applied);

  return v_applied;
end;
$$;

revoke all on function public.apply_updated_schedule(uuid) from public, anon;
grant execute on function public.apply_updated_schedule(uuid) to authenticated;

-- ── record_part_replacement ─────────────────────────────────────────────
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

  select cip.customer_id into v_customer_id
  from public.customer_installed_products cip where cip.id = v_schedule.installed_product_id;

  v_allowed := public.is_staff() or exists (
    select 1 from public.service_visits v
    join public.service_tickets st on st.id = v.ticket_id
    where st.customer_id = v_customer_id and v.technician_id = public.current_technician_id()
  );
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

revoke all on function public.record_part_replacement(uuid, date, uuid, uuid, text) from public, anon;
grant execute on function public.record_part_replacement(uuid, date, uuid, uuid, text) to authenticated;

-- ── get_customer_due_parts ──────────────────────────────────────────────
create or replace function public.get_customer_due_parts(p_customer_id uuid)
returns setof public.customer_part_schedules
language sql
security definer
set search_path to 'public'
as $$
  select cps.* from public.customer_part_schedules cps
  join public.customer_installed_products cip on cip.id = cps.installed_product_id
  where cip.customer_id = p_customer_id
    and cps.status in ('due_soon', 'due', 'overdue')
  order by cps.next_due_date
$$;

revoke all on function public.get_customer_due_parts(uuid) from public, anon;
grant execute on function public.get_customer_due_parts(uuid) to authenticated;

-- ── log_installed_products_for_invoice ──────────────────────────────────
-- Design decision (DECISIONS.md): rather than editing create_service_invoice
-- itself (a large, frequently-touched function — high merge-collision risk
-- for a function this plan does not need to modify the internals of), the
-- technician-side submit handler calls THIS separate RPC immediately after
-- create_service_invoice succeeds, with the same p_installations payload it
-- already builds (OnSiteVisitPage.tsx: handleCreateInvoice). Called at the
-- moment of visit submission, so installation_date here is the real
-- installation date already (today, IST) — not a stand-in invoice date; the
-- "default from invoice date, let Master correct" fallback in amendment 1
-- only matters for the one-time backfill of pre-existing installations_logged
-- rows (migration 100500), which predate this RPC's existence.
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
begin
  for v_item in select * from jsonb_to_recordset(p_installations) as x(product_id uuid, qty integer)
  loop
    perform public.create_installed_product(p_customer_id, v_item.product_id, v_today, p_visit_id, false);
  end loop;
end;
$$;

revoke all on function public.log_installed_products_for_invoice(uuid, uuid, jsonb) from public, anon;
grant execute on function public.log_installed_products_for_invoice(uuid, uuid, jsonb) to authenticated;
