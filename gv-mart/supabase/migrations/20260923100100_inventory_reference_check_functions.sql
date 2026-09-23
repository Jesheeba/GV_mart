-- Factor the "is this item referenced anywhere" predicate out of
-- delete_product/delete_spare/delete_gift (20260923100000) into its own
-- function per entity, so the UI can call it for an instant pre-check
-- (Skip button hint, hiding Delete) without duplicating the reference
-- list. The delete_* functions remain the actual enforcement — this is
-- purely so the same logic backs both.

create or replace function public.product_has_references(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from public.inventory where item_type = 'product' and item_id = p_id)
    or exists (select 1 from public.inventory_movements where item_type = 'product' and item_id = p_id)
    or exists (select 1 from public.quotation_items where item_type = 'product' and item_id = p_id)
    or exists (select 1 from public.invoice_items where item_type = 'product' and item_id = p_id)
    or exists (select 1 from public.technician_stock_levels where item_type = 'product' and item_id = p_id)
    or exists (select 1 from public.service_tickets where product_id = p_id)
    or exists (select 1 from public.amc_contracts where product_id = p_id)
    or exists (select 1 from public.warranties where product_id = p_id)
    or exists (select 1 from public.complaint_types where product_id = p_id)
    or exists (select 1 from public.product_spares where product_id = p_id)
    or exists (select 1 from public.sop_step_templates where product_id = p_id)
    or exists (select 1 from public.product_images where product_id = p_id)
    or exists (select 1 from public.product_documents where product_id = p_id)
    or exists (select 1 from public.product_videos where product_id = p_id)
    or exists (select 1 from public.product_related where product_id = p_id or related_product_id = p_id)
    or exists (select 1 from public.product_cta_overrides where product_id = p_id)
    or exists (select 1 from public.leads where product_id = p_id)
    or exists (select 1 from public.lead_items where product_id = p_id)
    or exists (select 1 from public.gift_exclusion_products where product_id = p_id)
    or exists (select 1 from public.product_tds_recommendations where product_id = p_id)
    or exists (select 1 from public.rental_contracts where product_id = p_id);
$$;

create or replace function public.spare_has_references(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from public.inventory where item_type = 'spare' and item_id = p_id)
    or exists (select 1 from public.inventory_movements where item_type = 'spare' and item_id = p_id)
    or exists (select 1 from public.quotation_items where item_type = 'spare' and item_id = p_id)
    or exists (select 1 from public.invoice_items where item_type = 'spare' and item_id = p_id)
    or exists (select 1 from public.technician_stock_levels where item_type = 'spare' and item_id = p_id)
    or exists (select 1 from public.service_spares_used where spare_id = p_id)
    or exists (select 1 from public.spare_handover_items where spare_id = p_id)
    or exists (select 1 from public.spare_return_items where spare_id = p_id)
    or exists (select 1 from public.amc_plan_covered_spares where spare_id = p_id)
    or exists (select 1 from public.complaint_type_spares where spare_id = p_id)
    or exists (select 1 from public.product_spares where spare_id = p_id)
    or exists (select 1 from public.leads where spare_id = p_id)
    or exists (select 1 from public.lead_items where spare_id = p_id);
$$;

create or replace function public.gift_has_references(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (select 1 from public.invoices where gift_id = p_id)
    or exists (select 1 from public.gift_logs where gift_id = p_id);
$$;

revoke execute on function public.product_has_references(uuid) from public;
revoke execute on function public.spare_has_references(uuid) from public;
revoke execute on function public.gift_has_references(uuid) from public;
grant execute on function public.product_has_references(uuid) to authenticated;
grant execute on function public.spare_has_references(uuid) to authenticated;
grant execute on function public.gift_has_references(uuid) to authenticated;

create or replace function public.delete_product(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  if not public.is_master() then
    raise exception 'delete_product: only master may delete a product';
  end if;

  select org_id into v_org_id from public.products where id = p_id;
  if v_org_id is null then
    raise exception 'delete_product: product % not found', p_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'delete_product: org mismatch';
  end if;

  if public.product_has_references(p_id) then
    raise exception 'ITEM_IN_USE: This product is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.products where id = p_id;
end;
$$;

create or replace function public.delete_spare(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  if not public.is_master() then
    raise exception 'delete_spare: only master may delete a spare';
  end if;

  select org_id into v_org_id from public.spares where id = p_id;
  if v_org_id is null then
    raise exception 'delete_spare: spare % not found', p_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'delete_spare: org mismatch';
  end if;

  if public.spare_has_references(p_id) then
    raise exception 'ITEM_IN_USE: This spare is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.spares where id = p_id;
end;
$$;

create or replace function public.delete_gift(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
begin
  if not public.is_master() then
    raise exception 'delete_gift: only master may delete a gift';
  end if;

  select org_id into v_org_id from public.gifts where id = p_id;
  if v_org_id is null then
    raise exception 'delete_gift: gift % not found', p_id;
  end if;
  if v_org_id is distinct from public.current_org_id() then
    raise exception 'delete_gift: org mismatch';
  end if;

  if public.gift_has_references(p_id) then
    raise exception 'ITEM_IN_USE: This gift is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.gifts where id = p_id;
end;
$$;
