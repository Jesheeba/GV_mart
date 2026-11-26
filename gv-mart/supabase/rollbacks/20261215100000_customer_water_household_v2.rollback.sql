-- Rollback for 20261215100000_customer_water_household_v2.sql.
-- Restores the STRUCTURE only: address water columns, the health-condition objects (verbatim from 20261108100000) and
-- the original edit guard. Dropped DATA (customer_health_profile rows, address water values, the settings flag) comes
-- back only from the pre-apply backup in _local_only/backups. Refuses if hardness/problems already hold data, rather
-- than silently discarding it.
do $$
begin
  if exists (select 1 from public.customers where water_hardness_ppm is not null or cardinality(household_problems) > 0) then
    raise exception 'rollback refused: customers.water_hardness_ppm / household_problems already hold data -- export it first';
  end if;
end $$;

-- original guard (4 water columns) -- replaced first so it no longer references the columns dropped below
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
  if auth.uid() is null then
    return new;
  end if;

  v_role := public.current_role();

  v_water_changed := (
    new.water_source is distinct from old.water_source
    or new.water_source_other is distinct from old.water_source_other
    or new.water_tds_ppm is distinct from old.water_tds_ppm
    or new.water_ph is distinct from old.water_ph
  );

  v_other_changed := (
    (to_jsonb(new) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
    is distinct from
    (to_jsonb(old) - array['water_source', 'water_source_other', 'water_tds_ppm', 'water_ph', 'updated_at'])
  );

  if v_role = 'operation_admin' and v_other_changed then
    raise exception 'customers: operation_admin may only edit the water profile fields';
  end if;

  if v_role is distinct from 'master' and v_role is distinct from 'operation_admin' and v_role is distinct from 'sales_admin' and v_water_changed then
    raise exception 'customers: only master, operation_admin or sales_admin may edit the water profile fields';
  end if;

  return new;
end;
$$;

alter table public.customers drop constraint customers_household_problems_check;
alter table public.customers drop column household_problems, drop column water_hardness_ppm;

alter table public.addresses add column if not exists water_source text;
alter table public.addresses add column if not exists water_tds integer;
alter table public.addresses add column if not exists water_ph numeric;
alter table public.addresses add column if not exists health_condition text;

-- ── technician visibility switch for health_condition (default off) ────────────────────────
alter table public.settings
  add column show_health_condition_to_technicians boolean not null default false;

-- ── health_condition: its own table. customers is not touched by any of this. ──────────────
create type household_health_level as enum ('none', 'normal', 'medium', 'high');

create table public.customer_health_profile (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  org_id uuid not null references public.organizations (id) on delete cascade,
  health_condition household_health_level not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

create index customer_health_profile_org_id_idx on public.customer_health_profile (org_id);

-- Stamps updated_at/updated_by from the real caller — not an audit trigger (nothing is copied
-- to audit_log or anywhere else), just this row's own metadata. SECURITY INVOKER, no
-- current_user/session_user test.
create or replace function public.stamp_customer_health_profile()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

create trigger stamp_customer_health_profile
  before insert or update on public.customer_health_profile
  for each row execute function public.stamp_customer_health_profile();

alter table public.customer_health_profile enable row level security;

-- This project auto-grants default privileges to anon/authenticated on new public-schema
-- objects (see 20260827-era "default_privileges anon EXECUTE leak" fix) — revoke everything
-- first, unconditionally, then grant back only the narrow authenticated access this table
-- actually needs. anon gets nothing at all.
revoke all on public.customer_health_profile from public, anon, authenticated;

-- master, operation_admin, sales_admin of the same org — reusing the existing is_staff()
-- helper (current_role() in ('master','operation_admin','sales_admin')), which is exactly
-- that role set. Read and write; no delete policy (not asked for). WITH CHECK also requires
-- the referenced customer to actually belong to the same org as the row being written —
-- without this, staff of one org could plant (or move) a health_condition row for a
-- customer_id that actually belongs to a different org, by simply quoting their own org_id
-- in the insert/update. The subquery's columns are explicitly table-qualified on BOTH sides
-- (customer_health_profile.customer_id / customer_health_profile.org_id vs c.id / c.org_id) —
-- leaving org_id unqualified here would resolve to c.org_id inside the subquery's own scope
-- (closest enclosing alias wins), making "c.org_id = org_id" a tautology that never actually
-- compares against the row being written.
create policy customer_health_profile_staff_select on public.customer_health_profile
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_health_profile_staff_insert on public.customer_health_profile
  for insert
  with check (
    org_id = public.current_org_id()
    and public.is_staff()
    and exists (
      select 1 from public.customers c
      where c.id = customer_health_profile.customer_id and c.org_id = customer_health_profile.org_id
    )
  );
create policy customer_health_profile_staff_update on public.customer_health_profile
  for update
  using (org_id = public.current_org_id() and public.is_staff())
  with check (
    org_id = public.current_org_id()
    and public.is_staff()
    and exists (
      select 1 from public.customers c
      where c.id = customer_health_profile.customer_id and c.org_id = customer_health_profile.org_id
    )
  );

-- the customer — their own row, read-only (no insert/update policy for the customer role).
create policy customer_health_profile_select_own on public.customer_health_profile
  for select using (customer_id = public.current_customer_id());

-- Technicians get no policy at all here — zero table access, by omission.
grant select, insert, update on public.customer_health_profile to authenticated;

-- ── gated read, a technician's ONLY path to this value (SECURITY DEFINER, bypasses RLS/
--    grants entirely — not affected by anything above). Staff always; the customer, their
--    own row; a technician, only when the org setting is on AND they have (or had) an
--    appointment with that customer — same exists() shape as the pre-existing
--    customers_select_own_technician RLS policy. The customer_health_profile lookup is
--    scoped by both customer_id AND org_id (belt-and-suspenders — customer_id is already
--    unique and already org-checked via v_org_id above, but this costs nothing and rules out
--    any possible cross-org row entirely at the SQL level, not just by construction). ───────
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
  select org_id into v_org_id from public.customers where id = p_customer_id;
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    return null;
  end if;

  select health_condition into v_level
  from public.customer_health_profile
  where customer_id = p_customer_id and org_id = v_org_id;

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

notify pgrst, 'reload schema';
