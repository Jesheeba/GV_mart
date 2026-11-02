-- Product Lifecycle & Automated Service Reminder System — small, cheap, read-only addition.
-- Masters Products page: "products without a lifecycle configured" filter/list.

create or replace function public.get_products_without_lifecycle_config()
returns table (product_id uuid, product_name text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.is_staff() then
    raise exception 'get_products_without_lifecycle_config: not authorized';
  end if;
  return query
    select p.id, p.name
    from public.products p
    where p.org_id = public.current_org_id()
      and not exists (
        select 1 from public.product_lifecycle_configs c
        where c.product_id = p.id and c.is_active
      )
    order by p.name;
end;
$$;
revoke all on function public.get_products_without_lifecycle_config() from public, anon;
grant execute on function public.get_products_without_lifecycle_config() to authenticated;
