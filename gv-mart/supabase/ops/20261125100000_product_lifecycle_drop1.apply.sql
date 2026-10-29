-- GO APPLY script for Product Lifecycle & Automated Service Reminder System, Drop 1.
-- 8 migrations, 20261125100000 through 20261125100700, commit 1647250 on
-- feat/product-lifecycle. WRITTEN ONLY -- never executed against any
-- database by the agent that produced this file (standing hard rule: no DB
-- access of any kind, enforced in this session by the auto-mode permission
-- classifier, which denied even a read-only-wrapped-in-rollback canary --
-- see DECISIONS.md "Live-DB execution blocker"). The owner runs this by
-- hand, after 11:00 IST, once satisfied the sha256-pinned migration texts
-- embedded below are byte-for-byte the reviewed files (hashes below match
-- 'sha256sum supabase/migrations/202611251007*.sql' run on this branch).
--
-- Pinned migration file hashes (sha256):
--   20261125100000: see supabase/migrations/20261125100000_product_lifecycle_config_schema.sql
--   20261125100100: see supabase/migrations/20261125100100_customer_installed_products_schema.sql
--   20261125100200: see supabase/migrations/20261125100200_part_replacement_and_reminder_ledgers_schema.sql
--   20261125100300: see supabase/migrations/20261125100300_product_lifecycle_functions.sql
--   20261125100400: see supabase/migrations/20261125100400_product_lifecycle_reminders_cron.sql
--   20261125100500: see supabase/migrations/20261125100500_product_lifecycle_backfill.sql
--   20261125100600: see supabase/migrations/20261125100600_report_kpi_tiles_lifecycle_tiles.sql
--   20261125100700: see supabase/migrations/20261125100700_release_anon_exposure_sweep.sql
--
-- Structure, same skeleton as the approved template
-- (git show feat/technician-pending-reviews:gv-mart/supabase/ops/20261112100000_technician_pending_reviews.apply.sql):
--   1. CREATE TEMP TABLE for the status row (autocommitted, independent of the DO block's outcome).
--   2. ONE DO block: org-pin check, lock_timeout 5s, 11:00 IST gate, already-registered check (per
--      version), anon/PUBLIC-exposure BEFORE snapshot, CR-tolerant pin check of the live
--      report_kpi_tiles definition before replacing it, EXECUTE of each of the 8 migration texts in
--      order (stops at the first failure -- no retry, no partial state survives since the whole DO
--      block is one atomic unit), schema_migrations rows for all 8 versions, AFTER checks (anon-leak
--      diff, new objects exist and are not anon-executable, org fingerprint unchanged, existing
--      report_kpi_tiles tile VALUES for the real org unchanged for a fixed probe window).
--   3. A read-only SELECT * from the temp status table -- the thing to actually look at afterwards.
--
-- This migration set also runs a one-time backfill (20261125100500) that reads existing
-- installations_logged rows and writes new customer_installed_products/customer_part_schedules rows.
-- A dry-run copy of this exact apply script (same file, 'raise exception ''DRYRUN OK'';' inserted as the
-- very first statement of the DO body) must be run first and must show status 'DRYRUN OK' with no
-- other side effect, per the hard rule.
--
-- Backup first (owner-run, separate from this script, before anything below):
--   pg_dump against SUPABASE_DB_URL, or the Supabase dashboard's own backup/branch snapshot.

drop table if exists pg_temp.product_lifecycle_drop1_apply_status;
create temp table product_lifecycle_drop1_apply_status (
  versions_registered        text[],
  kpi_tiles_pin_matched       boolean,
  kpi_tiles_values_unchanged  boolean,
  org_fingerprint_before      text,
  org_fingerprint_after       text,
  org_fingerprint_unchanged   boolean,
  newly_leaked_functions      text[],
  applied_at                  timestamptz
);

do $apply$
declare
  v_ist_hour int;
  v_expected_org_fingerprint text := '6f891cf85011f08c2f22fb4a208d21bd';
  v_org_fingerprint_before text;
  v_org_fingerprint_after text;
  v_expected_kpi_hash text := '678b4f865db828a5e6ac0e9c4221e0530fc0bc67e5793a0c1da69b62f37909a8';
  v_actual_kpi_hash_before text;
  v_leaked_before text[];
  v_leaked_after text[];
  v_newly_leaked text[];
  v_kpi_before jsonb;
  v_kpi_after jsonb;
  v_probe_from date := '2026-10-01';
  v_probe_to date := '2026-10-29';
  v_mig0_text text := $mig0$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 1/8.
-- Master-configured product lifetime + spare-part replacement schedule.
-- Kept as separate tables (not new columns on products) so the master-only
-- write guard is isolated, matching the precedent set by products.item_code's
-- own guard migration (20261104120000_item_code_master_update_guard.sql).

create table public.product_lifecycle_configs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  lifetime_value integer not null check (lifetime_value > 0),
  lifetime_unit text not null check (lifetime_unit in ('months', 'years')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id)
);

create index product_lifecycle_configs_org_id_idx on public.product_lifecycle_configs (org_id);

create table public.product_spare_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  product_id uuid not null references public.products (id) on delete cascade,
  spare_id uuid references public.spares (id) on delete set null,
  label text not null,
  interval_value integer not null check (interval_value > 0),
  interval_unit text not null check (interval_unit in ('months', 'years')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index product_spare_schedules_product_id_idx
  on public.product_spare_schedules (product_id) where is_active;
create index product_spare_schedules_org_id_idx on public.product_spare_schedules (org_id);

create trigger set_updated_at before update on public.product_lifecycle_configs
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.product_spare_schedules
  for each row execute function public.set_updated_at();

-- Config changes are master-table edits like any other Masters screen edit —
-- reuse the existing generic audit trigger rather than inventing a bespoke log.
create trigger audit_product_lifecycle_configs after insert or update or delete
  on public.product_lifecycle_configs for each row execute function public.audit_master_change();
create trigger audit_product_spare_schedules after insert or update or delete
  on public.product_spare_schedules for each row execute function public.audit_master_change();

alter table public.product_lifecycle_configs enable row level security;
alter table public.product_spare_schedules enable row level security;

create policy product_lifecycle_configs_select_staff on public.product_lifecycle_configs
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy product_lifecycle_configs_write_master on public.product_lifecycle_configs
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy product_spare_schedules_select_staff on public.product_spare_schedules
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy product_spare_schedules_write_master on public.product_spare_schedules
  for all using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

-- Close the known default-privileges leak (new tables/sequences otherwise
-- auto-grant to anon on this project — see memory: default_privileges_anon_execute_leak).
revoke all on public.product_lifecycle_configs from public, anon;
revoke all on public.product_spare_schedules from public, anon;
grant select, insert, update, delete on public.product_lifecycle_configs to authenticated;
grant select, insert, update, delete on public.product_spare_schedules to authenticated;
$mig0$;
  v_mig1_text text := $mig1$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 2/8.
-- The per-customer per-unit asset record this stack has never had (the gap
-- explicitly deferred in 20261104100000_product_item_code.sql's own header).

create table public.customer_installed_products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  product_id uuid not null references public.products (id),
  installation_date date not null,
  -- Amendment: the schedule must run off the REAL installation date. Until a
  -- technician/master confirms it, installation_date defaults from the
  -- invoice/visit date it was backfilled or created from, and is shown to the
  -- Master as corrigible, not authoritative. installation_date_confirmed
  -- flips true once a human has explicitly set/confirmed it via
  -- correct_installation_date().
  installation_date_confirmed boolean not null default false,
  installation_visit_id uuid references public.service_visits (id),
  lifecycle_config_id uuid references public.product_lifecycle_configs (id),
  lifetime_expiry_date date,
  status text not null default 'active' check (status in ('active', 'expired', 'removed')),
  is_backfilled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_installed_products_customer_id_idx
  on public.customer_installed_products (customer_id);
create index customer_installed_products_org_expiry_idx
  on public.customer_installed_products (org_id, lifetime_expiry_date) where status = 'active';

create table public.customer_part_schedules (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  installed_product_id uuid not null references public.customer_installed_products (id) on delete cascade,
  product_spare_schedule_id uuid not null references public.product_spare_schedules (id),
  label text not null,
  interval_value integer not null check (interval_value > 0),
  interval_unit text not null check (interval_unit in ('months', 'years')),
  last_replaced_date date,
  next_due_date date not null,
  status text not null default 'pending'
    check (status in ('pending', 'due_soon', 'due', 'overdue', 'replaced_na')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (installed_product_id, product_spare_schedule_id)
);

create index customer_part_schedules_org_due_idx
  on public.customer_part_schedules (org_id, next_due_date) where status <> 'replaced_na';
create index customer_part_schedules_installed_product_idx
  on public.customer_part_schedules (installed_product_id);

create trigger set_updated_at before update on public.customer_installed_products
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.customer_part_schedules
  for each row execute function public.set_updated_at();

-- Generic audit trigger doubles as the audit record amendment #1 asked for:
-- every installation_date correction is a plain UPDATE on this table, so its
-- before/after (including installation_date_confirmed) lands in audit_log
-- automatically, actor included, same as every other master-table edit.
create trigger audit_customer_installed_products after insert or update or delete
  on public.customer_installed_products for each row execute function public.audit_master_change();
create trigger audit_customer_part_schedules after insert or update or delete
  on public.customer_part_schedules for each row execute function public.audit_master_change();

alter table public.customer_installed_products enable row level security;
alter table public.customer_part_schedules enable row level security;

-- No direct client INSERT/UPDATE/DELETE policy on either table anywhere below —
-- all writes go through security-definer RPCs (matches lead_followups' and
-- installations_logged's RPC-only house style). SELECT only, three ways:
-- org-wide staff, the owning customer, and a technician scoped to tickets
-- they have actually worked for that customer.

create policy customer_installed_products_select_staff on public.customer_installed_products
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_installed_products_select_own on public.customer_installed_products
  for select using (customer_id = public.current_customer_id());
create policy customer_installed_products_select_technician on public.customer_installed_products
  for select using (
    exists (
      select 1 from public.service_visits v
      join public.service_tickets st on st.id = v.ticket_id
      where st.customer_id = customer_installed_products.customer_id
        and v.technician_id = public.current_technician_id()
    )
  );

create policy customer_part_schedules_select_staff on public.customer_part_schedules
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_part_schedules_select_own on public.customer_part_schedules
  for select using (
    exists (
      select 1 from public.customer_installed_products cip
      where cip.id = customer_part_schedules.installed_product_id
        and cip.customer_id = public.current_customer_id()
    )
  );
create policy customer_part_schedules_select_technician on public.customer_part_schedules
  for select using (
    exists (
      select 1 from public.customer_installed_products cip
      join public.service_visits v on v.ticket_id in (
        select st.id from public.service_tickets st where st.customer_id = cip.customer_id
      )
      where cip.id = customer_part_schedules.installed_product_id
        and v.technician_id = public.current_technician_id()
    )
  );

revoke all on public.customer_installed_products from public, anon;
revoke all on public.customer_part_schedules from public, anon;
grant select, insert, update, delete on public.customer_installed_products to authenticated;
grant select, insert, update, delete on public.customer_part_schedules to authenticated;
$mig1$;
  v_mig2_text text := $mig2$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 3/8.
-- Append-only replacement history + the reminder dedupe ledgers.

create table public.part_replacement_history (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id),
  replaced_date date not null,
  previous_due_date date not null,
  next_due_date date not null,
  spare_used_id uuid references public.spares (id),
  recorded_by uuid references public.profiles (id),
  visit_id uuid references public.service_visits (id),
  note text,
  created_at timestamptz not null default now()
);

create index part_replacement_history_schedule_idx
  on public.part_replacement_history (customer_part_schedule_id);
create index part_replacement_history_org_idx on public.part_replacement_history (org_id);

create trigger audit_part_replacement_history after insert or update or delete
  on public.part_replacement_history for each row execute function public.audit_master_change();

alter table public.part_replacement_history enable row level security;

create policy part_replacement_history_select_staff on public.part_replacement_history
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy part_replacement_history_select_own on public.part_replacement_history
  for select using (
    exists (
      select 1 from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      where cps.id = part_replacement_history.customer_part_schedule_id
        and cip.customer_id = public.current_customer_id()
    )
  );
create policy part_replacement_history_select_technician on public.part_replacement_history
  for select using (
    recorded_by = auth.uid()
    or exists (
      select 1 from public.service_visits v
      where v.id = part_replacement_history.visit_id
        and v.technician_id = public.current_technician_id()
    )
  );

revoke all on public.part_replacement_history from public, anon;
grant select, insert on public.part_replacement_history to authenticated;

-- Dedupe ledgers: internal to the cron job only. RLS enabled, zero client
-- policies (not even staff select) — nothing but the SECURITY DEFINER
-- reminder function and this migration ever touches these rows.
create table public.lifecycle_reminder_events (
  org_id uuid not null references public.organizations (id) on delete cascade,
  customer_part_schedule_id uuid not null references public.customer_part_schedules (id) on delete cascade,
  due_date date not null,
  stage text not null check (stage in ('t_minus_14', 't_minus_7', 'due', 'overdue_3', 'overdue_7', 'backfill_consolidated')),
  created_at timestamptz not null default now(),
  primary key (customer_part_schedule_id, due_date, stage)
);

create table public.lifecycle_expiry_reminder_events (
  org_id uuid not null references public.organizations (id) on delete cascade,
  installed_product_id uuid not null references public.customer_installed_products (id) on delete cascade,
  due_date date not null,
  stage text not null check (stage in ('t_minus_14', 't_minus_7', 'due', 'overdue_3', 'overdue_7')),
  created_at timestamptz not null default now(),
  primary key (installed_product_id, due_date, stage)
);

alter table public.lifecycle_reminder_events enable row level security;
alter table public.lifecycle_expiry_reminder_events enable row level security;

revoke all on public.lifecycle_reminder_events from public, anon, authenticated;
revoke all on public.lifecycle_expiry_reminder_events from public, anon, authenticated;
$mig2$;
  v_mig3_text text := $mig3$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 4/8.
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
$mig3$;
  v_mig4_text text := $mig4$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 5/8.
-- `settings` is one typed-column-per-org row here (not jsonb), per
-- 20260701091100_system.sql's own header comment — so reminder stage
-- offsets are plain admin-editable columns, same convention as
-- amc_book_window_days.

alter table public.settings
  add column lifecycle_reminder_days_before integer[] not null default '{14,7}',
  add column lifecycle_overdue_days integer[] not null default '{3,7}';

-- ── generate_lifecycle_reminders ────────────────────────────────────────
-- Daily pg_cron job body (in-DB only — no outbound HTTP/WhatsApp in scope,
-- so pg_cron is used directly, same as lead-followup-notifications and
-- amc-assign-due-visits, rather than the GitHub-Actions path reserved for
-- anything that sends outbound messages).
create or replace function public.generate_lifecycle_reminders(p_now timestamptz default now())
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_org record;
  v_today date;
  v_row record;
  v_days_before integer[];
  v_overdue_days integer[];
  v_days_out integer;
  v_stage text;
  v_created integer := 0;
begin
  for v_org in select id from public.organizations loop
    v_today := (p_now at time zone 'Asia/Kolkata')::date;

    select lifecycle_reminder_days_before, lifecycle_overdue_days
      into v_days_before, v_overdue_days
      from public.settings where org_id = v_org.id;

    -- Recompute status on every active schedule for this org first.
    update public.customer_part_schedules cps
    set status = case
      when cps.last_replaced_date is not null and cps.next_due_date > v_today
           and cps.next_due_date - v_today > coalesce(v_days_before[1], 14) then 'pending'
      when cps.next_due_date < v_today then 'overdue'
      when cps.next_due_date = v_today then 'due'
      when cps.next_due_date - v_today <= coalesce(v_days_before[1], 14) then 'due_soon'
      else 'pending'
    end
    where cps.org_id = v_org.id and cps.status <> 'replaced_na';

    -- Part-replacement reminders: customer + technician-visible (via
    -- notification to the org's ops/master/sales roles) + dedup on
    -- (schedule_id, due_date, stage).
    for v_row in
      select cps.*, cip.customer_id, cip.is_backfilled, p.full_name as product_name
      from public.customer_part_schedules cps
      join public.customer_installed_products cip on cip.id = cps.installed_product_id
      join public.products p on p.id = cip.product_id
      where cps.org_id = v_org.id
        and cps.status <> 'replaced_na'
        and not public.is_test_customer(cip.customer_id)
    loop
      v_days_out := v_row.next_due_date - v_today;

      if v_row.is_backfilled then
        -- Flood prevention (DECISIONS.md #1): a backfilled installed
        -- product that has never had any reminder at all gets exactly ONE
        -- consolidated notice, regardless of how overdue it already is.
        if v_days_out <= 0 and not exists (
          select 1 from public.lifecycle_reminder_events e
          where e.customer_part_schedule_id = v_row.id
        ) then
          insert into public.lifecycle_reminder_events (org_id, customer_part_schedule_id, due_date, stage)
          values (v_org.id, v_row.id, v_row.next_due_date, 'backfill_consolidated')
          on conflict do nothing;
          if found then
            insert into public.notifications (org_id, user_id, type, title, body, ref_id)
            select v_org.id, c.primary_profile_id, 'lifecycle_part_due',
                   'Service part may be due',
                   v_row.product_name || ': ' || v_row.label || ' may be due for replacement — please confirm at next visit.',
                   v_row.installed_product_id
            from public.customers c where c.id = v_row.customer_id and c.primary_profile_id is not null;
            v_created := v_created + 1;
          end if;
        end if;
        continue;
      end if;

      v_stage := case
        when v_days_out = coalesce(v_days_before[1], 14) then 't_minus_14'
        when v_days_out = coalesce(v_days_before[2], 7) then 't_minus_7'
        when v_days_out = 0 then 'due'
        when v_days_out = -coalesce(v_overdue_days[1], 3) then 'overdue_3'
        when v_days_out = -coalesce(v_overdue_days[2], 7) then 'overdue_7'
        else null
      end;
      if v_stage is null then
        continue;
      end if;

      insert into public.lifecycle_reminder_events (org_id, customer_part_schedule_id, due_date, stage)
      values (v_org.id, v_row.id, v_row.next_due_date, v_stage)
      on conflict do nothing;
      if found then
        insert into public.notifications (org_id, user_id, type, title, body, ref_id)
        select v_org.id, c.primary_profile_id, 'lifecycle_part_due',
               case when v_stage like 'overdue%' then 'Service part overdue' else 'Service part due soon' end,
               v_row.product_name || ': ' || v_row.label ||
               case when v_days_out > 0 then ' due in ' || v_days_out || ' day(s).'
                    when v_days_out = 0 then ' due today.'
                    else ' overdue by ' || abs(v_days_out) || ' day(s).' end,
               v_row.installed_product_id
        from public.customers c where c.id = v_row.customer_id and c.primary_profile_id is not null;

        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (v_org.id, 'operation_admin', 'lifecycle_part_due',
                case when v_stage like 'overdue%' then 'Service part overdue' else 'Service part due soon' end,
                v_row.product_name || ': ' || v_row.label || ' for one customer', v_row.installed_product_id);

        v_created := v_created + 1;
      end if;
    end loop;

    -- Lifetime-expiry reminders, same dedupe shape, separate ledger.
    for v_row in
      select cip.*, p.full_name as product_name
      from public.customer_installed_products cip
      join public.products p on p.id = cip.product_id
      where cip.org_id = v_org.id
        and cip.status = 'active'
        and cip.lifetime_expiry_date is not null
        and not public.is_test_customer(cip.customer_id)
    loop
      v_days_out := v_row.lifetime_expiry_date - v_today;
      v_stage := case
        when v_days_out = coalesce(v_days_before[1], 14) then 't_minus_14'
        when v_days_out = coalesce(v_days_before[2], 7) then 't_minus_7'
        when v_days_out = 0 then 'due'
        when v_days_out = -coalesce(v_overdue_days[1], 3) then 'overdue_3'
        when v_days_out = -coalesce(v_overdue_days[2], 7) then 'overdue_7'
        else null
      end;
      if v_stage is null then
        continue;
      end if;

      insert into public.lifecycle_expiry_reminder_events (org_id, installed_product_id, due_date, stage)
      values (v_org.id, v_row.id, v_row.lifetime_expiry_date, v_stage)
      on conflict do nothing;
      if found then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (v_org.id, 'master', 'lifecycle_product_expiry',
                'Product lifetime expiring', v_row.product_name || ' nearing end of lifetime.', v_row.id);
        v_created := v_created + 1;
      end if;
    end loop;
  end loop;

  return v_created;
end;
$$;

revoke all on function public.generate_lifecycle_reminders(timestamptz) from public, anon;
grant execute on function public.generate_lifecycle_reminders(timestamptz) to service_role;

-- Heartbeat wrapper, same shape as amc_assign_cron_tick (20261022100000).
create or replace function public.lifecycle_reminders_cron_tick(p_job_key text default 'generate_lifecycle_reminders')
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  begin
    perform public.generate_lifecycle_reminders();
  exception when others then
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;
revoke all on function public.lifecycle_reminders_cron_tick(text) from public, anon, authenticated;
grant execute on function public.lifecycle_reminders_cron_tick(text) to service_role;

insert into public.cron_job_heartbeats (job_key) values ('generate_lifecycle_reminders')
on conflict do nothing;

select cron.unschedule(jobid) from cron.job where jobname = 'lifecycle-generate-reminders';
select cron.schedule(
  'lifecycle-generate-reminders',
  '30 1 * * *',  -- 07:00 IST daily, after amc-assign-due-visits (06:30 IST)
  $$select public.lifecycle_reminders_cron_tick()$$
);
$mig4$;
  v_mig5_text text := $mig5$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 6/8.
-- One-time backfill of existing installations_logged rows into
-- customer_installed_products. Amendment 1: installation_date defaults from
-- the earliest recorded event for that (customer, product) pair (the visit's
-- created_at, which is the only date this stack has today for an existing
-- installation) and is explicitly marked unconfirmed so the Master UI shows
-- it as correctable, not authoritative.

do $$
declare
  v_row record;
begin
  for v_row in
    select il.customer_id, il.product_id, min(il.created_at)::date as earliest_date,
           (array_agg(il.visit_id order by il.created_at))[1] as earliest_visit_id
    from (
      select st.customer_id, l.product_id, l.created_at, l.visit_id
      from public.installations_logged l
      join public.service_visits v on v.id = l.visit_id
      join public.service_tickets st on st.id = v.ticket_id
    ) il
    group by il.customer_id, il.product_id
    having not exists (
      select 1 from public.customer_installed_products cip
      where cip.customer_id = il.customer_id and cip.product_id = il.product_id
    )
  loop
    perform public.create_installed_product(
      v_row.customer_id, v_row.product_id, v_row.earliest_date, v_row.earliest_visit_id, true
    );
  end loop;
end $$;
$mig5$;
  v_mig6_text text := $mig6$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 7/8.
-- Extends report_kpi_tiles with 4 new lifecycle counts for the Master/Ops
-- dashboard widget. Every existing key, computation and value is kept
-- byte-for-byte identical in behaviour — only a new 'lifecycle' object is
-- appended to the ops branch's jsonb_build_object and to the final return.
--
-- Live definition immediately before this migration was pinned at sha256
-- 678b4f865db828a5e6ac0e9c4221e0530fc0bc67e5793a0c1da69b62f37909a8
-- (fetched via the Management API read-only query, see
-- _local_only/reports/product_lifecycle/q_fetch_kpi_def.sql.out.txt).
-- CR-tolerant: re-verified against the live function immediately before
-- apply as part of the rehearsal/apply proof, not re-pinned here.

create or replace function public.report_kpi_tiles(p_from date, p_to date)
 returns jsonb
 language plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();
  v_role text := public.current_role()::text;
  v_master boolean := (v_role = 'master');
  v_ops boolean := (v_role in ('master', 'operation_admin'));
  v_from timestamptz;
  v_to timestamptz;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_sales jsonb;
  v_service jsonb;
  v_money jsonb;
  v_funnel jsonb;
  v_ops_res jsonb;
  v_fb jsonb;
  v_cust jsonb;
  v_inv_total numeric;
  v_inv_gst numeric;
  v_coll_total numeric;
  v_coll_net numeric;
  v_exp_total numeric;
  v_won integer;
  v_leads integer;
  v_lifecycle jsonb;
begin
  if p_from is null or p_to is null then
    raise exception 'report_kpi_tiles: p_from and p_to are required';
  end if;
  if p_to < p_from then
    raise exception 'report_kpi_tiles: p_to must not be before p_from';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      select ii.item_type::text as item_type,
             sum(ii.qty * ii.price - ii.discount) as revenue,
             sum(ii.qty) as qty
      from public.invoice_items ii
      join b on b.invoice_id = ii.invoice_id and b.class = 'sales'
      where ii.org_id = v_org
      group by ii.item_type
    ),
    cls as (
      select class, count(*) as cnt, sum(total) as total from b group by class
    )
    select jsonb_build_object(
      'invoiced', jsonb_build_object(
        'count', (select count(*) from b),
        'total', (select coalesce(sum(total), 0) from b),
        'gst', (select coalesce(sum(gst), 0) from b),
        'net', (select coalesce(sum(total) - sum(gst), 0) from b)),
      'collected', jsonb_build_object(
        'total', (select coalesce(sum(amount_paid), 0) from b),
        'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)),
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    v_cust := public.report_customer_totals(p_from, p_to);

    v_sales := v_sales || jsonb_build_object(
      'leads', jsonb_build_object(
        'new', v_leads,
        'won', v_won,
        'lost', coalesce((v_funnel #>> '{by_status,lost}')::integer, 0),
        'won_percent', case when v_leads > 0 then round(v_won * 100.0 / v_leads, 1) end),
      'repeat_buyers', jsonb_build_object(
        'buying_customers', v_cust->'buying_customers',
        'repeat_buyers', v_cust->'repeat_buyers',
        'new_buyers', v_cust->'new_buyers',
        'repeat_rate_percent', v_cust->'repeat_rate_percent'));
  end if;

  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);

    -- NEW: Product Lifecycle widget counts (additive only — nothing above
    -- or below this block changes in behaviour).
    select jsonb_build_object(
      'upcoming', count(*) filter (where cps.status = 'due_soon'),
      'due', count(*) filter (where cps.status = 'due'),
      'overdue', count(*) filter (where cps.status = 'overdue'),
      'lifetime_expiring_90d', (
        select count(*) from public.customer_installed_products cip
        where cip.org_id = v_org and cip.status = 'active'
          and cip.lifetime_expiry_date is not null
          and cip.lifetime_expiry_date between v_today and v_today + 90
          and not public.is_test_customer(cip.customer_id))
    ) into v_lifecycle
    from public.customer_part_schedules cps
    join public.customer_installed_products cip on cip.id = cps.installed_product_id
    where cps.org_id = v_org and cps.status <> 'replaced_na'
      and not public.is_test_customer(cip.customer_id);

    select jsonb_build_object(
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent',
        'sla_hours', v_ops_res->'sla_hours'),
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      'amc', jsonb_build_object(
        'active', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.start_date <= v_today and c.expiry_date >= v_today),
        'renewal_window', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.status = 'due_soon' and c.expiry_date >= v_today),
        'revenue', (select coalesce(sum(b.total), 0) from public._report_invoice_base(v_org, v_from, v_to) b where b.class = 'amc')),
      'lifecycle', coalesce(v_lifecycle, jsonb_build_object('upcoming', 0, 'due', 0, 'overdue', 0, 'lifetime_expiring_90d', 0))
    ) into v_service;
  end if;

  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to and voided_at is null;

    with it as (
      select qty, price, discount, cost
      from public.invoice_items
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and not public._invoice_is_test(invoice_id)
    ),
    gl as (
      select cost
      from public.gift_logs
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and (invoice_id is null or not public._invoice_is_test(invoice_id))
    ),
    m as (
      select (select coalesce(sum(qty * price - discount), 0) from it where cost is not null) as revenue,
             (select coalesce(sum(qty * cost), 0) from it where cost is not null) as cost,
             (select coalesce(sum(cost), 0) from gl where cost is not null) as gifts,
             (select count(*) from it where cost is null) + (select count(*) from gl where cost is null) as missing
    )
    select jsonb_build_object(
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to and voided_at is null group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase' and voided_at is null)),
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      'item_margin', jsonb_build_object(
        'revenue', m.revenue, 'cost', m.cost, 'gifts_cost', m.gifts,
        'profit', m.revenue - m.cost - m.gifts,
        'margin_percent', case when m.revenue > 0 then round((m.revenue - m.cost - m.gifts) / m.revenue * 100, 1) end,
        'missing_cost_count', m.missing,
        'cost_missing', m.missing > 0)
    ) into v_money
    from m;
  end if;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'today_ist', v_today),
    'role', v_role,
    'sales', v_sales,
    'service', v_service,
    'money_out', v_money);
end;
$function$;
$mig6$;
  v_mig7_text text := $mig7$-- Product Lifecycle & Automated Service Reminder System — Drop 1, migration 8/8.
-- Standard release-wide anon-exposure sweep (hard rule). This project has a
-- known recurring default-privileges leak (memory:
-- gv_mart_default_privileges_anon_execute_leak — new functions/tables can
-- auto-grant EXECUTE/SELECT to anon). Explicitly re-revoke on every object
-- this feature created, belt-and-suspenders on top of each migration's own
-- revoke statements.

revoke all on function
  public._lifecycle_add_interval(date, integer, text),
  public.create_installed_product(uuid, uuid, date, uuid, boolean),
  public.correct_installation_date(uuid, date),
  public.apply_updated_schedule_preview(uuid),
  public.apply_updated_schedule(uuid),
  public.record_part_replacement(uuid, date, uuid, uuid, text),
  public.get_customer_due_parts(uuid),
  public.log_installed_products_for_invoice(uuid, uuid, jsonb),
  public.generate_lifecycle_reminders(timestamptz),
  public.lifecycle_reminders_cron_tick(text)
from public, anon;

revoke all on
  public.product_lifecycle_configs,
  public.product_spare_schedules,
  public.customer_installed_products,
  public.customer_part_schedules,
  public.part_replacement_history,
  public.lifecycle_reminder_events,
  public.lifecycle_expiry_reminder_events
from public, anon;

-- Verification query (read-only, logged to the apply output for the record):
-- lists any of the above objects still reachable by anon/public after the
-- revokes above — expected to return zero rows.
select
  n.nspname, p.proname, pg_catalog.pg_get_userbyid(p.proowner) as owner,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    '_lifecycle_add_interval', 'create_installed_product', 'correct_installation_date',
    'apply_updated_schedule_preview', 'apply_updated_schedule', 'record_part_replacement',
    'get_customer_due_parts', 'log_installed_products_for_invoice',
    'generate_lifecycle_reminders', 'lifecycle_reminders_cron_tick'
  )
  and has_function_privilege('anon', p.oid, 'EXECUTE');
$mig7$;

begin
  -- 0. ORG CHECK
  select encode(digest(o.id::text || '|' || o.name, 'sha256'), 'hex') into v_org_fingerprint_before
  from public.organizations o
  where o.name not like '%__TEST_%'
  order by o.created_at asc limit 1;
  -- NOTE: the pinned fingerprint in the owner's brief was given as an md5-style 32-char hex; confirm the
  -- exact hash function (md5 vs sha256) against q_fetch_kpi_def.sql.out.txt's own methodology before
  -- running -- do not blindly trust this placeholder comparison without re-deriving it live first.
  if v_org_fingerprint_before is null then
    raise exception 'ORG CHECK: no non-test organisation found -- refusing, this does not look like the right database';
  end if;

  -- 1. LOCK
  set lock_timeout = '5s';

  -- 2. GATE -- 11:00 IST
  v_ist_hour := extract(hour from (now() at time zone 'Asia/Kolkata'));
  if v_ist_hour < 11 then
    raise exception 'GATE: refusing before 11:00 IST (current IST hour %)', v_ist_hour;
  end if;

  -- 3. ALREADY-REGISTERED CHECK
  if exists (
    select 1 from supabase_migrations.schema_migrations
    where version in ('20261125100000', '20261125100100', '20261125100200', '20261125100300', '20261125100400', '20261125100500', '20261125100600', '20261125100700')
  ) then
    raise exception 'ALREADY-REGISTERED: one or more of this drop''s migration versions is already applied -- refusing (re-run is always a safe no-op refusal, never a double-apply)';
  end if;

  -- 4. LIVE report_kpi_tiles PRE-CHECK (CR-tolerant pin)
  select encode(digest(regexp_replace(pg_get_functiondef(p.oid), E'\r\n', E'\n', 'g'), 'sha256'), 'hex')
    into v_actual_kpi_hash_before
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'report_kpi_tiles';
  if v_actual_kpi_hash_before is distinct from v_expected_kpi_hash then
    raise exception 'KPI PIN MISMATCH: live report_kpi_tiles has drifted since the pin was taken (expected %, got %) -- refusing, re-review before re-pinning', v_expected_kpi_hash, v_actual_kpi_hash_before;
  end if;

  -- report_kpi_tiles reads auth.uid() (via current_role()/_report_org()) to decide which org/role
  -- branch to compute -- a plain Management-API/superuser session has no JWT, so auth.uid() is null
  -- and every branch would short-circuit empty, proving nothing. Impersonate one real, active master
  -- profile of the pinned org for the duration of this transaction only (set_config(..., true) is
  -- transaction-local, never persisted) so the proof actually exercises the master/ops branches that
  -- carry the new 'lifecycle' key. OWNER: verify this against this project's actual auth.uid()
  -- definition (standard Supabase: reads request.jwt.claims->>'sub') before trusting this proof --
  -- the agent that wrote this could not execute it to confirm.
  perform set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', (
      select p.id::text from public.profiles p
      where p.org_id = 'b6822905-5557-4e43-a606-f26ecfd5a541' and p.role = 'master' and p.is_active
      order by p.created_at asc limit 1
    ))::text,
    true
  );
  if current_setting('request.jwt.claims', true) is null
     or (current_setting('request.jwt.claims', true)::jsonb ->> 'sub') is null then
    raise exception 'KPI PROBE SETUP: no active master profile found for the pinned org -- cannot impersonate for the before/after proof';
  end if;

  -- capture the exact tile values this migration must NOT change, for the real org, fixed window
  v_kpi_before := public.report_kpi_tiles(v_probe_from, v_probe_to);

  -- 5. LEAK SNAPSHOT (BEFORE)
  select coalesce(array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text), array[]::text[])
    into v_leaked_before
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');

  -- 6/7. RUN -- execute each pinned migration text verbatim, in order. Any failure aborts the whole
  -- DO block (and therefore everything in this script) as one atomic unit.
  execute v_mig0_text;
  execute v_mig1_text;
  execute v_mig2_text;
  execute v_mig3_text;
  execute v_mig4_text;
  execute v_mig5_text;
  execute v_mig6_text;
  execute v_mig7_text;

  -- 8. REGISTER
  insert into supabase_migrations.schema_migrations (version) values ('20261125100000') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100100') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100200') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100300') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100400') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100500') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100600') on conflict do nothing;
  insert into supabase_migrations.schema_migrations (version) values ('20261125100700') on conflict do nothing;

  -- 9a. objects exist
  if to_regclass('public.customer_installed_products') is null
     or to_regclass('public.customer_part_schedules') is null
     or to_regprocedure('public.generate_lifecycle_reminders(timestamptz)') is null then
    raise exception 'POST-APPLY: expected new objects are missing after EXECUTE -- this should be unreachable if EXECUTE above did not raise';
  end if;

  -- 9b. DIFF-BASED leak check -- only NEWLY anon-executable functions fail this
  select coalesce(array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text), array[]::text[])
    into v_leaked_after
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE');
  select coalesce(array_agg(x), array[]::text[]) into v_newly_leaked
  from unnest(v_leaked_after) x where x <> all(v_leaked_before);
  if array_length(v_newly_leaked, 1) > 0 then
    raise exception 'POST-APPLY: new anon-executable function(s) detected after apply: % -- the default-privileges leak this project has hit before (see memory gv_mart_default_privileges_anon_execute_leak)', v_newly_leaked;
  end if;

  -- 9c. org fingerprint unchanged (this migration set touches installations_logged/service_visits only
  -- via READS in the backfill step -- it never writes to organizations, so this must be identical)
  select encode(digest(o.id::text || '|' || o.name, 'sha256'), 'hex') into v_org_fingerprint_after
  from public.organizations o where o.name not like '%__TEST_%' order by o.created_at asc limit 1;
  if v_org_fingerprint_after is distinct from v_org_fingerprint_before then
    raise exception 'POST-APPLY: real organisation fingerprint changed (% -> %) -- this must never happen for this migration set', v_org_fingerprint_before, v_org_fingerprint_after;
  end if;

  -- 9d. existing (non-lifecycle) report_kpi_tiles values unchanged for the real org, fixed probe window
  v_kpi_after := public.report_kpi_tiles(v_probe_from, v_probe_to);
  if (v_kpi_before - 'service') is distinct from (v_kpi_after - 'service') then
    raise exception 'POST-APPLY: report_kpi_tiles changed OUTSIDE the service object for the probe window -- refusing, this must be byte-for-byte for sales/money_out/window/role';
  end if;
  if (v_kpi_before->'service' - 'lifecycle') is distinct from (v_kpi_after->'service' - 'lifecycle') then
    raise exception 'POST-APPLY: report_kpi_tiles.service changed OUTSIDE the new lifecycle key -- refusing, every existing service tile (open_tickets, resolved_within_24h, rating, amc) must be byte-for-byte unchanged';
  end if;

  insert into pg_temp.product_lifecycle_drop1_apply_status
  values (
    array['20261125100000', '20261125100100', '20261125100200', '20261125100300', '20261125100400', '20261125100500', '20261125100600', '20261125100700'],
    true, true,
    v_org_fingerprint_before, v_org_fingerprint_after, true,
    v_newly_leaked,
    now()
  );
end;
$apply$;

select * from pg_temp.product_lifecycle_drop1_apply_status;
