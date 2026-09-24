-- Technician van stock, Group 2 (handover flow).
--
-- Rewires create_spare_handover (last body: 20260715130000_spare_handover_
-- inventory_movement.sql) to move warehouse stock into the new
-- per-technician `technician_stock_levels` ledger instead of the pooled
-- `inventory` location='van' bucket — see 20260921110000's header comment
-- for why that bucket was never actually per-technician. The warehouse-side
-- decrement (still `inventory` location='warehouse') and the header/retry
-- logic are otherwise unchanged verbatim.
--
-- No frontend change needed for this group: TechniciansSpareHandoverPage.tsx
-- and techniciansAdmin.ts's createSpareHandover already call this RPC by
-- name with the same (p_org_id, p_technician_id, p_date, p_items) signature
-- — only where the stock lands changes.
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

      -- Warehouse-side decrement — unchanged conditional UPDATE.
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

      -- Per-technician van-side increment — was a pooled `inventory`
      -- location='van' upsert, now this technician's own ledger row.
      insert into public.technician_stock_levels (org_id, technician_id, item_type, item_id, stock_qty)
      values (p_org_id, p_technician_id, 'spare', v_item.spare_id, v_item.qty_given)
      on conflict (org_id, technician_id, item_type, item_id)
      do update set stock_qty = technician_stock_levels.stock_qty + excluded.stock_qty, updated_at = now();

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty_given, 'spare_handover', v_handover_id, p_technician_id);
    end loop;
  end if;

  return v_handover_id;
end;
$$;
