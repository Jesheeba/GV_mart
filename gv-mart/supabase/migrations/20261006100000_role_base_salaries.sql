-- Salary/Incentive system, Phase 1 Part A: master-editable base salary per
-- non-technician staff role. Technicians are NOT covered here —
-- technician_tiers.monthly_salary stays their sole source of base pay.
-- role_key is free text on purpose (Helper, Operation Manager, Admin-Marketing
-- are salary labels, not login roles; the user_role enum is untouched).
-- Every seeded row is ₹0: the master types real figures in Masters > Role Salaries.

create table public.role_base_salaries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  role_key text not null check (length(btrim(role_key)) > 0),
  label text not null,
  monthly_base numeric(12, 2) not null default 0 check (monthly_base >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, role_key)
);

create index role_base_salaries_org_id_idx on public.role_base_salaries (org_id);

alter table public.role_base_salaries enable row level security;

-- Salary figures are sensitive: master-only read AND write.
create policy role_base_salaries_master on public.role_base_salaries for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger set_updated_at before update on public.role_base_salaries
  for each row execute function public.set_updated_at();

create trigger audit_role_base_salaries after insert or update or delete on public.role_base_salaries
  for each row execute function public.audit_master_change();

-- Link a staff member to a role base. Nullable; free text matching
-- role_base_salaries.role_key (no FK: the master can rename/delete a role row
-- without a cascade rewriting people's profiles — an unmatched key simply
-- pre-fills nothing).
alter table public.profiles add column staff_role_key text;

-- It decides pay, so only master may set it (profiles_update_own would
-- otherwise let any staff member edit their own).
create or replace function public.guard_profile_staff_role_key()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.staff_role_key is distinct from old.staff_role_key and auth.uid() is not null and not public.is_master() then
    raise exception 'Only master can change a staff member''s salary role';
  end if;
  return new;
end;
$$;

create trigger guard_profile_staff_role_key before update of staff_role_key on public.profiles
  for each row execute function public.guard_profile_staff_role_key();

-- Seed role rows only (all ₹0). master/operation_admin/sales_admin are the
-- non-technician roles actually in use; the rest are the salary labels from
-- the client's sheet.
insert into public.role_base_salaries (org_id, role_key, label, monthly_base)
select o.id, r.role_key, r.label, 0
from public.organizations o
cross join (values
  ('helper', 'Helper'),
  ('operation_manager', 'Operation Manager'),
  ('admin_operation', 'Admin-Operation'),
  ('admin_sales', 'Admin-Sales'),
  ('admin_marketing', 'Admin-Marketing'),
  ('master', 'Master / Owner')
) as r(role_key, label)
on conflict (org_id, role_key) do nothing;
