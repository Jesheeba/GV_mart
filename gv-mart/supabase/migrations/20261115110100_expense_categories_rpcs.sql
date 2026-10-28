-- Accounts follow-up, Feature A, step 2 of 3 — owner-managed category
-- create/rename/deactivate/delete, all master-only SECURITY DEFINER.
-- The real enforcement that a system category is locked lives in the
-- trigger (previous migration); these checks are a friendlier error for
-- the UI.

create or replace function public.create_expense_category(p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'create_expense_category: master only';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'create_expense_category: name is required';
  end if;

  insert into public.expense_categories (org_id, name)
  values (v_org, btrim(p_name))
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'create_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.create_expense_category(text) from public, anon, authenticated;
grant execute on function public.create_expense_category(text) to authenticated;

create or replace function public.rename_expense_category(p_id uuid, p_name text)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'rename_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'rename_expense_category: a system category cannot be renamed';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'rename_expense_category: name is required';
  end if;

  update public.expense_categories
    set name = btrim(p_name)
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'rename_expense_category: category % not found', p_id;
  end if;
  return v_row;
exception
  when unique_violation then
    raise exception 'rename_expense_category: a category named "%" already exists', btrim(p_name);
end;
$$;
revoke all on function public.rename_expense_category(uuid, text) from public, anon, authenticated;
grant execute on function public.rename_expense_category(uuid, text) to authenticated;

create or replace function public.deactivate_expense_category(p_id uuid)
returns public.expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_row public.expense_categories;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'deactivate_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'deactivate_expense_category: a system category cannot be deactivated';
  end if;

  update public.expense_categories
    set is_active = false
    where id = p_id and org_id = v_org
    returning * into v_row;
  if v_row.id is null then
    raise exception 'deactivate_expense_category: category % not found', p_id;
  end if;
  return v_row;
end;
$$;
revoke all on function public.deactivate_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.deactivate_expense_category(uuid) to authenticated;

create or replace function public.delete_expense_category(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_deleted int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'delete_expense_category: master only';
  end if;
  if exists (select 1 from public.expense_categories where id = p_id and org_id = v_org and is_system) then
    raise exception 'delete_expense_category: a system category cannot be deleted';
  end if;
  if exists (select 1 from public.expenses where category_id = p_id) then
    raise exception 'delete_expense_category: category % is used by at least one expense', p_id;
  end if;

  delete from public.expense_categories where id = p_id and org_id = v_org;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then
    raise exception 'delete_expense_category: category % not found', p_id;
  end if;
end;
$$;
revoke all on function public.delete_expense_category(uuid) from public, anon, authenticated;
grant execute on function public.delete_expense_category(uuid) to authenticated;
