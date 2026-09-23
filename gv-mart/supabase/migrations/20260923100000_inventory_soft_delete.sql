-- Inventory soft-delete ("Skip"/"Revoke") for products/spares/gifts.
--
-- Today's Delete is a hard DELETE with no reference check at all
-- (src/services/masters.ts deleteProduct/deleteSpare/deleteGift). Several
-- referencing tables are ON DELETE CASCADE or SET NULL, so a hard delete
-- can silently destroy related rows (product_images, sop_step_templates,
-- complaint_types, ...) or silently blank a historical reference
-- (service_tickets.product_id, leads.product_id/spare_id, invoices.gift_id,
-- ...) instead of erroring. And item_type/item_id on inventory,
-- inventory_movements, quotation_items, invoice_items and
-- technician_stock_levels is polymorphic with no DB FK at all, so nothing
-- stops those from silently orphaning today.
--
-- Fix: gifts gets the same is_active flag products/spares already have
-- (20260730170000_product_spare_mapping_and_active_flags.sql), and Delete
-- is only ever allowed through delete_product/delete_spare/delete_gift
-- below, which explicitly check every referencing table (not just the
-- ones with a real RESTRICT FK) before deleting, and direct DELETE
-- privilege on the three tables is revoked so the functions are the only
-- path — a UI-only guard is one API call away from being bypassed.

alter table public.gifts add column if not exists is_active boolean not null default true;

-- ── delete_product ──────────────────────────────────────────────────────
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

  if exists (select 1 from public.inventory where item_type = 'product' and item_id = p_id)
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
    or exists (select 1 from public.rental_contracts where product_id = p_id)
  then
    raise exception 'ITEM_IN_USE: This product is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.products where id = p_id;
end;
$$;

-- ── delete_spare ────────────────────────────────────────────────────────
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

  if exists (select 1 from public.inventory where item_type = 'spare' and item_id = p_id)
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
    or exists (select 1 from public.lead_items where spare_id = p_id)
  then
    raise exception 'ITEM_IN_USE: This spare is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.spares where id = p_id;
end;
$$;

-- ── delete_gift ─────────────────────────────────────────────────────────
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

  if exists (select 1 from public.invoices where gift_id = p_id)
    or exists (select 1 from public.gift_logs where gift_id = p_id)
  then
    raise exception 'ITEM_IN_USE: This gift is referenced elsewhere and cannot be deleted. Use Skip instead.';
  end if;

  delete from public.gifts where id = p_id;
end;
$$;

revoke delete on public.products from authenticated;
revoke delete on public.spares from authenticated;
revoke delete on public.gifts from authenticated;

revoke execute on function public.delete_product(uuid) from public;
revoke execute on function public.delete_spare(uuid) from public;
revoke execute on function public.delete_gift(uuid) from public;
grant execute on function public.delete_product(uuid) to authenticated;
grant execute on function public.delete_spare(uuid) to authenticated;
grant execute on function public.delete_gift(uuid) to authenticated;
