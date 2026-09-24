-- Technician van stock, Group 3 (return flow).
--
-- Mirrors create_spare_handover exactly, in reverse: ops staff records what
-- a technician physically handed back, atomically moving stock from that
-- technician's `technician_stock_levels` row into `inventory`
-- location='warehouse', and fails loudly (not silently clamping) if the
-- requested qty exceeds what the technician's ledger says they hold — that
-- mirrors handover's "fails loudly if warehouse can't cover it" behavior
-- exactly, just on the other side of the same ledger.
--
-- `security invoker` + explicit is_ops_staff() check, same as
-- create_spare_handover (not `security definer` like create_service_invoice
-- — that one runs as the technician themselves and needs to bypass RLS on
-- tables technicians have no direct policy for; this one runs as ops staff,
-- who already have write policies on every table it touches).
--
-- inventory_movements convention going forward (see also the next
-- migration's service_invoice rewire): when `technician_id` is set, positive
-- change_qty means to *that technician's van* balance; negative change_qty
-- against a handover/return/shortfall row with technician_id set means the
-- WAREHOUSE side of a movement attributable to that technician — i.e. the
-- sign always matches whichever pool (van or warehouse) is named by the
-- movement's reason, not a fixed "always warehouse" convention. Concretely:
-- 'spare_handover' -> warehouse -qty (already live); 'return' -> warehouse
-- +qty; 'service_use_shortfall' -> warehouse -qty; 'service_use_van' -> that
-- technician's van -qty.
create or replace function public.create_spare_return(
  p_org_id uuid,
  p_technician_id uuid,
  p_date date,
  p_items jsonb -- [{spare_id, qty_returned}, ...]
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_return_id uuid;
  v_item record;
  v_new_tech_stock integer;
  v_have integer;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_spare_return: org mismatch';
  end if;
  if not public.is_ops_staff() then
    raise exception 'create_spare_return: caller is not ops staff';
  end if;

  insert into public.spare_returns (org_id, technician_id, date)
  values (p_org_id, p_technician_id, p_date)
  returning id into v_return_id;

  if p_items is not null and jsonb_array_length(p_items) > 0 then
    for v_item in select * from jsonb_to_recordset(p_items) as x(spare_id uuid, qty_returned integer)
    loop
      if v_item.qty_returned is null or v_item.qty_returned <= 0 then
        continue;
      end if;

      -- Van-side decrement — conditional UPDATE guarded by the technician's
      -- own ledger balance, mirrors create_spare_handover's warehouse guard.
      update public.technician_stock_levels
        set stock_qty = stock_qty - v_item.qty_returned, updated_at = now()
        where org_id = p_org_id and technician_id = p_technician_id
          and item_type = 'spare' and item_id = v_item.spare_id and stock_qty >= v_item.qty_returned
        returning stock_qty into v_new_tech_stock;

      if v_new_tech_stock is null then
        select stock_qty into v_have
          from public.technician_stock_levels
          where org_id = p_org_id and technician_id = p_technician_id
            and item_type = 'spare' and item_id = v_item.spare_id;
        raise exception 'create_spare_return: technician does not hold enough of spare % to return (need %, have %)',
          v_item.spare_id, v_item.qty_returned, coalesce(v_have, 0);
      end if;

      insert into public.spare_return_items (org_id, return_id, spare_id, qty_returned)
      values (p_org_id, v_return_id, v_item.spare_id, v_item.qty_returned);

      -- Warehouse-side increment. Same unique index
      -- (org_id, item_type, item_id, location) create_spare_handover already
      -- relies on makes this a safe atomic upsert.
      insert into public.inventory (org_id, item_type, item_id, stock_qty, location)
      values (p_org_id, 'spare', v_item.spare_id, v_item.qty_returned, 'warehouse')
      on conflict (org_id, item_type, item_id, location)
      do update set stock_qty = inventory.stock_qty + excluded.stock_qty;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id, technician_id)
      values (p_org_id, 'spare', v_item.spare_id, v_item.qty_returned, 'return', v_return_id, p_technician_id);
    end loop;
  end if;

  return v_return_id;
end;
$$;
