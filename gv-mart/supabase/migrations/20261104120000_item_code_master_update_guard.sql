-- P4 part 3: a defense-in-depth UPDATE guard on products.item_code, same shape as guard_technician_tier_change /
-- tier_id_master_guard (20261001140000).
--
-- Today products_write_master already restricts EVERY write on products (insert/update/delete, every column,
-- item_code included) to master: `using (org_id = current_org_id() and is_master())` /
-- `with check (...)` (20260701091300_rls.sql). No role other than master can reach an UPDATE of this row at
-- all right now, so under today's policy set this trigger has nothing of its own to block that RLS does not
-- already block first.
--
-- It exists anyway, scoped to item_code only, for the same reason tier_id_master_guard exists even though
-- technicians_write_ops already gates technicians by org: that policy covers a WHOLE TABLE. If products_write_master
-- is ever loosened to let operation_admin (or any non-master role) edit other product fields — stock, pricing,
-- description — item_code does not silently come along for the ride; it stays master-only unless this trigger is
-- deliberately loosened too. Other columns on products are completely untouched by this migration; they remain
-- exactly as editable (or not) as products_write_master already makes them today.
--
-- SECURITY INVOKER (not SECURITY DEFINER, unlike tier_id_master_guard): the only thing evaluated is
-- public.is_master(), which is already SECURITY DEFINER and self-contained — this trigger needs no elevated
-- privilege of its own, and running as invoker means it can never do more than the session already could.
-- search_path is still pinned, as every function in this schema does.
--
-- auth.uid() is null for service-role / migration writes (and for anon, which per 20261016500000 has NO table
-- privilege on products at all — not UPDATE, not even SELECT — so an anon connection can never reach this trigger
-- in the first place; the auth.uid() is null bypass below is for service-role/migration writes only and is not a
-- path anon can use). Fires only when item_code actually changes value (BEFORE UPDATE OF item_code, plus an
-- explicit IS DISTINCT FROM so touching the column in the SET list without changing its value is still a no-op).

create or replace function public.guard_item_code_update()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
begin
  if new.item_code is distinct from old.item_code and auth.uid() is not null and not public.is_master() then
    raise exception 'Only master can change a product''s item_code';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_item_code_update on public.products;
create trigger guard_item_code_update before update of item_code on public.products
  for each row execute function public.guard_item_code_update();
