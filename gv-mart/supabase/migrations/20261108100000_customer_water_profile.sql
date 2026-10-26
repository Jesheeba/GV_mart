-- Customer water and household profile. Spec: FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md.
--
-- Reuses the existing water_source_type enum (20260915180000_ro_water_quality_readings.sql) —
-- these four columns are a persistent customer-level profile, separate from the per-visit
-- ro_checklists reading, which is left untouched.
--
-- ROLE DECISION (owner, 2026-10-26): the spec's "master, operation_admin and sales_admin can
-- edit" line assumed operation_admin already had customers write access — it does not
-- (customers_write_sales only covers master + sales_admin, via is_sales_staff()). The owner's
-- resolution: these four new columns are editable by master and operation_admin only;
-- sales_admin keeps its existing full write access to every other customers column but is
-- newly blocked from touching these four. operation_admin gets a brand-new, update-only,
-- org-scoped RLS grant that the guard trigger below then restricts to ONLY these four columns
-- (it has no broader customers access). health_condition stays *readable* by master,
-- operation_admin, sales_admin and the customer themselves (read is not the same as write) —
-- enforced by column-level privilege + the get_customer_health_condition function below, not
-- by this trigger.

-- ── profile columns on customers ────────────────────────────────────────────────────────────
alter table public.customers
  add column water_source water_source_type,
  add column water_source_other text check (water_source_other is null or char_length(water_source_other) <= 100),
  add column water_tds_ppm numeric(6, 2) check (water_tds_ppm is null or water_tds_ppm >= 0),
  add column water_ph numeric(4, 2) check (water_ph is null or water_ph between 0 and 14);

alter table public.customers
  add constraint customers_water_source_other_only_with_other
  check (water_source_other is null or water_source = 'other');

create type household_health_level as enum ('none', 'normal', 'medium', 'high');

alter table public.customers
  add column health_condition household_health_level;

-- No stored family-member count column, by design (spec 3.1/9): the count is always derived
-- from customer_members where moved_out_at is null, so it can never drift from the real list.

-- ── technician visibility switch for health_condition (default off) ────────────────────────
alter table public.settings
  add column show_health_condition_to_technicians boolean not null default false;

-- ── role guard: only master/operation_admin may change the 4 new columns; operation_admin may
--    change ONLY the 4 new columns (it has no other customers write access at all) ───────────
-- SECURITY INVOKER (not DEFINER) — this is exactly the "client-detecting trigger" case, so no
-- current_user/session_user test is used or needed; it calls the existing current_role()
-- stable helper (itself SECURITY DEFINER, reading profiles by auth.uid()), same pattern as the
-- pre-existing guard_customer_self_update trigger on this same table.
create or replace function public.guard_water_profile_edit_roles()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_role public.user_role;
  v_water_changed boolean;
  v_other_changed boolean;
begin
  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
    or new.health_condition is distinct from old.health_condition
  );

  v_other_changed := (
    (to_jsonb(new) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'health_condition', 'updated_at'])
    is distinct from
    (to_jsonb(old) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'health_condition', 'updated_at'])
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water and household profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_water_changed then
    raise exception 'customers: only master or operation_admin may edit the water and household profile fields';
  end if;

  return new;
end;
$$;

create trigger guard_water_profile_edit_roles
  before update on public.customers
  for each row execute function public.guard_water_profile_edit_roles();

-- operation_admin currently has NO write policy on customers at all — this grants it UPDATE
-- only (never insert/delete), org-scoped; the trigger above is what actually confines it to
-- the 4 new columns, since RLS itself is row-level, not column-level.
create policy customers_write_operation_admin on public.customers
  for update
  using (org_id = public.current_org_id() and public.current_role() = 'operation_admin')
  with check (org_id = public.current_org_id() and public.current_role() = 'operation_admin');

-- ── health_condition is sensitive: never selectable via the raw table, by anyone, so a direct
--    REST/table query can't leak it regardless of what the UI's own select list asks for.
--    UPDATE privilege is untouched (master/operation_admin still write it through a normal
--    table update; the trigger above is what gates who). Reads go only through the function
--    below, which runs as the table owner and so is unaffected by this column revoke. ────────
revoke select (health_condition) on public.customers from authenticated, anon;

-- ── gated read: staff always; the customer, their own row; a technician, only when the org
--    setting is on AND they have (or had) an appointment with that customer — same exists()
--    shape as the pre-existing customers_select_own_technician RLS policy. ────────────────────
create or replace function public.get_customer_health_condition(p_customer_id uuid)
returns household_health_level
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_level household_health_level;
  v_technician_id uuid := public.current_technician_id();
begin
  select org_id, health_condition into v_org_id, v_level
  from public.customers
  where id = p_customer_id;

  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    return null;
  end if;

  if public.is_staff() then
    return v_level;
  end if;

  if p_customer_id = public.current_customer_id() then
    return v_level;
  end if;

  if v_technician_id is not null
     and exists (select 1 from public.settings s where s.org_id = v_org_id and s.show_health_condition_to_technicians)
     and exists (
       select 1
       from public.service_tickets t
       join public.appointments a on a.ticket_id = t.id
       where t.customer_id = p_customer_id and a.technician_id = v_technician_id
     )
  then
    return v_level;
  end if;

  return null;
end;
$$;

revoke all on function public.get_customer_health_condition(uuid) from public, anon;
grant execute on function public.get_customer_health_condition(uuid) to authenticated;
