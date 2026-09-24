-- Technician van stock, Group 5b (low-stock ALERT, not just the Stock tab's
-- visual badge).
--
-- TechniciansStockLevelsTab.tsx (uncommitted, this session's earlier group)
-- already flags a technician's row as "Low" client-side when
-- 0 < stock_qty <= the spare's own warehouse `inventory.min_stock` row — but
-- that's a badge you only see if you're already looking at the Stock tab.
-- It reuses the warehouse row's min_stock as a *shared* threshold rather than
-- inventing a new per-technician column (see that tab's own comment) — this
-- migration keeps that same choice for consistency: one threshold, one
-- source of truth, not two competing numbers for the same spare.
--
-- This adds the actual notification half, mirroring
-- 20260715300000_operational_alerts.sql's `_auto_draft_purchase_order`
-- pattern exactly: an event-driven trigger (not a scan) that fires on the
-- downward crossing into the low band, and only on that crossing — no extra
-- dedupe table needed, same as that trigger. No PO auto-draft here: the
-- fix for a technician running low is a handover, not a purchase order, so
-- this only ever inserts a notification.
create or replace function public._notify_technician_low_stock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_threshold integer;
  v_tech_name text;
  v_spare_name text;
begin
  select min_stock into v_threshold
    from public.inventory
    where org_id = new.org_id and item_type = new.item_type and item_id = new.item_id and location = 'warehouse';

  -- Same shape as _auto_draft_purchase_order's guard, plus stock_qty > 0:
  -- a technician at exactly 0 has nothing to be "low" on (they need a
  -- fresh handover, not a restock nudge) — matches the Stock tab's own
  -- `stock_qty > 0` condition for the "Low" badge and its `.gt("stock_qty", 0)`
  -- query filter (a zeroed-out row doesn't even show in that tab).
  if v_threshold is null
     or new.stock_qty <= 0
     or new.stock_qty > v_threshold
     or (old.stock_qty is not null and old.stock_qty > 0 and old.stock_qty <= v_threshold) then
    return new;
  end if;

  select p.full_name into v_tech_name
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = new.technician_id;
  select name into v_spare_name from public.spares where id = new.item_id;

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    new.org_id, 'operation_admin', 'technician_low_stock', 'Technician stock low',
    format('%s''s van stock for %s is at %s (warehouse min %s). Consider a handover.',
      coalesce(v_tech_name, 'A technician'), coalesce(v_spare_name, 'this spare'), new.stock_qty, v_threshold),
    new.id
  );

  return new;
end;
$$;

create trigger technician_stock_levels_notify_low
  after insert or update of stock_qty on public.technician_stock_levels
  for each row execute function public._notify_technician_low_stock();
