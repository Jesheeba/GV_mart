drop trigger if exists seed_system_expense_categories_on_org on public.organizations;
drop function if exists public._trg_seed_system_expense_categories();
drop function if exists public.seed_system_expense_categories(uuid);
alter table public.expenses drop column if exists category_id;
drop trigger if exists aaa_guard_expense_category_system_locked on public.expense_categories;
drop function if exists public._guard_expense_category_system_locked();
drop trigger if exists audit_expense_categories on public.expense_categories;
drop trigger if exists set_updated_at on public.expense_categories;
drop table if exists public.expense_categories;
