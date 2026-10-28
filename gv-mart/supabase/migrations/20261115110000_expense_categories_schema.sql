-- Accounts follow-up, Feature A, step 1 of 3 — owner-managed expense
-- categories ("Under Category"), additive alongside the existing fixed
-- `expenses.category` enum (DECISIONS.md D9) — the enum, its RLS, and
-- every path that writes it (including HR/Staff-Salary's "Log to
-- Accounts", which writes category='salary') are untouched by this
-- migration. No overlap with feat/monthly-expenses-v2 (DECISIONS.md D8).

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  -- System categories (one per existing expense_category enum value, plus
  -- Incentives) are seeded per-org and can never be renamed, deactivated or
  -- deleted — enforced below by a trigger, not only by the RPCs.
  is_system boolean not null default false,
  enum_value public.expense_category,
  is_active boolean not null default true,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index expense_categories_org_name_ci_idx on public.expense_categories (org_id, lower(name));
create unique index expense_categories_org_enum_idx on public.expense_categories (org_id, enum_value) where enum_value is not null;
create index expense_categories_org_idx on public.expense_categories (org_id);

alter table public.expense_categories enable row level security;
revoke all on public.expense_categories from public, anon, authenticated;

-- Matches expenses_select_master precedent (20260701091300_rls.sql):
-- category management is a master-only Accounts concern.
create policy expense_categories_select_master on public.expense_categories
  for select using (org_id = public.current_org_id() and public.is_master());
grant select on public.expense_categories to authenticated;

create trigger set_updated_at before update on public.expense_categories
  for each row execute function public.set_updated_at();
create trigger audit_expense_categories after insert or update or delete on public.expense_categories
  for each row execute function public.audit_master_change();

-- Real DB enforcement (owner's condition 4: "enforced in DB, not only
-- UI") that a system category's name/active flag can never change, and it
-- can never be deleted. The RPCs add a friendlier error on top of this.
create or replace function public._guard_expense_category_system_locked()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'expense_categories: a system category cannot be deleted';
    end if;
    return old;
  end if;
  if old.is_system and (
    new.name is distinct from old.name
    or new.is_active is distinct from old.is_active
    or new.is_system is distinct from old.is_system
    or new.enum_value is distinct from old.enum_value
    or new.org_id is distinct from old.org_id
  ) then
    raise exception 'expense_categories: a system category cannot be renamed, deactivated, deleted, moved to another organisation, or have its system flag or enum mapping changed';
  end if;
  return new;
end;
$$;
revoke all on function public._guard_expense_category_system_locked() from public, anon, authenticated;

drop trigger if exists aaa_guard_expense_category_system_locked on public.expense_categories;
create trigger aaa_guard_expense_category_system_locked
  before update or delete on public.expense_categories
  for each row execute function public._guard_expense_category_system_locked();

-- Additive nullable FK — existing rows stay "uncategorised"; the existing
-- `category` enum column is never touched.
alter table public.expenses add column if not exists category_id uuid references public.expense_categories (id) on delete set null;
create index if not exists expenses_category_id_idx on public.expenses (category_id);

-- ── seed: one system category per existing enum value, plus Incentives ──
create or replace function public.seed_system_expense_categories(p_org_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.expense_categories (org_id, name, is_system, enum_value)
  values
    (p_org_id, 'Marketing Expenses', true, 'marketing'),
    (p_org_id, 'Stationery', true, 'stationery'),
    (p_org_id, 'Salary', true, 'salary'),
    (p_org_id, 'Petrol', true, 'petrol'),
    (p_org_id, 'Purchase', true, 'purchase'),
    (p_org_id, 'Other', true, 'other'),
    (p_org_id, 'Rent', true, 'rent'),
    (p_org_id, 'Electricity', true, 'electricity'),
    (p_org_id, 'Parking', true, 'parking'),
    (p_org_id, 'Ad Campaign', true, 'ad_campaign'),
    (p_org_id, 'Video Generation', true, 'video_generation'),
    (p_org_id, 'Incentives', true, null)
  on conflict (org_id, lower(name)) do nothing;
$$;
revoke execute on function public.seed_system_expense_categories(uuid) from public, anon, authenticated;

select public.seed_system_expense_categories(id) from public.organizations;

create or replace function public._trg_seed_system_expense_categories()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_system_expense_categories(new.id);
  return new;
end;
$$;
revoke all on function public._trg_seed_system_expense_categories() from public, anon, authenticated;

drop trigger if exists seed_system_expense_categories_on_org on public.organizations;
create trigger seed_system_expense_categories_on_org after insert on public.organizations
  for each row execute function public._trg_seed_system_expense_categories();

-- Idempotent, additive: only ever fills a null category_id, never
-- overwrites one a user later picked manually. Safe to re-run.
update public.expenses e
  set category_id = (
    select ec.id from public.expense_categories ec
    where ec.org_id = e.org_id and ec.enum_value = e.category and ec.is_system
  )
  where e.category_id is null;
