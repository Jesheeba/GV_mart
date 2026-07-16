-- Fix: create_spare_handover (20260702200100_technicians_admin_functions.sql)
-- inserted spare_handovers/spare_handover_items rows as pure paperwork and
-- never touched `inventory` — so handing spares to a technician had zero
-- effect on stock. Meanwhile create_service_invoice
-- (20260702120000_technician_phase7_functions.sql lines ~153-168) already
-- tries to deduct spares used on a job from `location='van'` stock first,
-- falling back to `location='warehouse'` only when no van row covers the
-- qty — but no write path ever created a van row, so that fallback silently
-- masked the gap on every single spare usage.
--
-- Fix: when a handover line is recorded, atomically move qty_given units of
-- stock from location='warehouse' to location='van' for that org+spare,
-- mirroring the exact conditional-UPDATE-with-stock-guard pattern
-- create_service_invoice already uses for its van/warehouse decrement. If
-- warehouse stock can't cover a line, the handover now fails loudly instead
-- of recording a quantity that was never actually on the shelf — that is
-- the intended behavior change, not a regression.
--
-- `inventory` already has a unique index on (org_id, item_type, item_id,
-- location) (20260701090300_catalog_inventory.sql line 73:
-- inventory_item_location_idx), so the van-side increment is a plain
-- `insert ... on conflict (...) do update` upsert — no manual
-- select-for-update dance needed.
--
-- `inventory_movements.reason` is a bare `text not null` column with no
-- check constraint (verified across every migration touching that table),
-- so no constraint needs extending to add the new 'spare_handover' reason
-- value alongside the existing 'sale' / 'purchase_receipt' / 'service_visit'
-- conventions.
--
-- Everything else (header insert + retry-on-conflict dance, org/role
-- checks, per-item qty_given <= 0 skip) is unchanged from
-- 20260702200100_technicians_admin_functions.sql.
create or replace function public.create_spare_handover(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_given}, ...]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_handover_id uuid;
  v_item record;
  v_new_stock integer;
  v_have integer;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_handover: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_handover: caller is not ops staff';
  end if;

  insert into public.spare_handovers (org_id, technician_id, date, status)
  values (p_org_id, p_technician_id, p_date, 'pending')
  on conflict do nothing
  returning id into v_handover_id;

  -- date has no unique constraint (a technician can have more than one
  -- handover per day in principle), so on_conflict above never actually
  -- fires today — kept defensive in case a future migration adds one.
  if v_handover_id is null then
    insert into public.spare_handovers (org_id, technician_id, date, status)
    values (p_org_id, p_technician_id, p_date, 'pending')
    returning id into v_handover_id;
  end if;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_given integer)
    loop
      if v_item.qty_given is null or v_item.qty_given <= 0 then
        continue;
      end if;
      insert into public.spare_handover_items (org_id, handover_id, spare_id, qty_given)
      values (p_org_id, v_handover_id, v_item.spare_id, v_item.qty_given);

      -- Move stock warehouse -> van for this line, atomically. Conditional
      -- UPDATE guarded by stock_qty >= qty, mirrors create_service_invoice's
      -- van/warehouse decrement exactly.
      update public.inventory
        set stock_qty = stock_qty - v_item.qty_given
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'warehouse' and stock_qty >= v_item.qty_given
        returning stock_qty into v_new_stock;

      if v_new_stock is null then
        select stock_qty into v_have
          from public.inventory
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse';
        raise exception 'create_spare_handover: insufficient warehouse stock for spare % (need %, have %)',
          v_item.spare_id, v_item.qty_given, coalesce(v_have, 0);
      end if;

      -- Upsert the van-side row. Unique index on (org_id, item_type,
      -- item_id, location) makes this a safe atomic upsert.
      insert into public.inventory (org_id, item_type, item_id, stock_qty, location)
      values (p_org_id, 'spare', v_item.spare_id, v_item.qty_given, 'van')
      on conflict (org_id, item_type, item_id, location)
      do update set stock_qty = inventory.stock_qty + excluded.stock_qty;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty_given, 'spare_handover', v_handover_id);
    end loop;
  end if;

  return v_handover_id;
end;
$$;
