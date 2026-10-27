-- Close the direct-write hole in spare_handovers / spare_handover_items (2026-10-27 review).
--
-- Found (same review that produced 20261114100000_spare_handover_completion_gaps.sql, but
-- deliberately left unfixed there as out of scope): spare_handovers_write_own_technician and
-- spare_handover_items_write_own_technician (both in 20260701091300_rls.sql) are `FOR ALL`
-- policies keyed only on technician_id = current_technician_id(). `FOR ALL` covers
-- SELECT/INSERT/UPDATE/DELETE, so a technician holding nothing but the app's normal
-- authenticated session could INSERT a fake spare_handovers row (and spare_handover_items
-- lines) directly against PostgREST, bypassing create_spare_handover() entirely -- no
-- warehouse decrement, no technician_stock_levels increment, no inventory_movements row.
-- Every stock-movement side effect create_spare_handover() exists to enforce is skippable
-- this way. The same review checked spare_returns and technician_stock_levels for the same
-- pattern and found neither has it: both tables only ever got technician_stock_levels_select_own /
-- spare_returns_select_own (SELECT-only, 20260921110000_technician_van_stock_schema.sql) plus
-- technician_stock_levels_write_ops / spare_returns_write_ops (FOR ALL, is_ops_staff() only,
-- 20260921121000_technician_stock_write_policy.sql) -- no technician write policy exists on
-- either table to begin with, so this migration makes NO changes to them. Confirmed by
-- grepping every `create policy ... on (technician_stock_levels|spare_returns|
-- spare_return_items)` in supabase/migrations/ -- see the review bundle for the exact grep.
--
-- Precedent: 20261016130000_ratings_no_direct_writes.sql closed the identical FOR-ALL-to-
-- technician shape on `ratings`. That fix also revoked INSERT/UPDATE/DELETE/TRUNCATE on
-- ratings from authenticated entirely, because EVERY legitimate ratings writer (including
-- ops staff) already went through a SECURITY DEFINER function. That is NOT true here:
-- create_spare_handover() and admin_sign_spare_handover() (both ops-staff-only) are
-- `security invoker`, by design (20260921120000's and 20260702200100's own comments: ops
-- writes are authorized by RLS + an explicit is_ops_staff() check, not a bypassing definer),
-- and they run as the calling ops-staff member under the single shared Postgres role
-- `authenticated` (there is no separate DB role per app role -- master/operation_admin/
-- technician/sales_admin is only a profiles.role column). Revoking the table-level INSERT/
-- UPDATE/DELETE grant from `authenticated` would silently break those two ops-staff flows
-- along with every other `authenticated`-held session, technician or not. So unlike the
-- ratings fix, this migration touches ONLY the RLS policies, not the table-level GRANTs:
-- spare_handovers_write_ops / spare_handover_items_write_ops (FOR ALL, is_ops_staff()) are
-- left completely untouched, and master/operation_admin keep writing exactly as they do today
-- (create_spare_handover, admin_sign_spare_handover, both unchanged).
--
-- One real complication the ratings precedent did not have: confirm_spare_handover (the
-- technician's own signature-confirmation RPC, 20260702120000_technician_phase7_functions.sql)
-- is ALSO `security invoker`, and its own comment there says so explicitly: "Plain update
-- would already pass `spare_handovers_write_own_technician` RLS, but centralising the 'both
-- signatures must be present' rule server-side avoids re-implementing it in every offline-sync
-- retry path." That means confirm_spare_handover's UPDATE relies on the very policy this
-- migration drops -- naively dropping spare_handovers_write_own_technician with no
-- replacement would make every technician's confirm_spare_handover call silently update 0 rows
-- (Postgres RLS denies an UPDATE by excluding the row from the USING-filtered scan, not by
-- raising an error -- there is no pre-existing row to violate a WITH CHECK against), which
-- confirm_spare_handover already turns into a raised "handover % not found for this
-- technician" exception via its own `if not found` check. So confirm_spare_handover is
-- redefined below, verbatim except `security invoker` -> `security definer` (bypassing RLS,
-- the same way report_spare_handover_discrepancy and create_service_invoice already do) plus
-- `set search_path = public` (it had none before; safe to add since every reference inside is
-- already schema-qualified with `public.`). Its existing `where ... and technician_id =
-- v_tech_id` / `if not found then raise` ownership check is untouched and is now the ONLY
-- gate on this write (no longer backed up by RLS too) -- that check was already correct and
-- already the one actually doing the ownership enforcement day to day; RLS was redundant with
-- it, never the sole guard.
--
-- Net result for a technician: SELECT on their own spare_handovers / spare_handover_items rows
-- is preserved exactly (new SELECT-only policies, identical USING condition to the dropped
-- FOR ALL policies -- nothing about read access changes). Direct INSERT/UPDATE/DELETE against
-- either table is gone. Every legitimate technician write still works, unchanged, because every
-- one of them already went through an RPC: create_spare_handover (ops-only, unaffected),
-- confirm_spare_handover (now definer, fixed here), report_spare_handover_discrepancy (already
-- definer, unaffected by any of this).
--
-- No data is touched. No column, table, or existing admin-facing behavior changes.

drop policy if exists spare_handovers_write_own_technician on public.spare_handovers;

create policy spare_handovers_select_own_technician on public.spare_handovers for select
  using (public.spare_handovers.technician_id = public.current_technician_id());

drop policy if exists spare_handover_items_write_own_technician on public.spare_handover_items;

create policy spare_handover_items_select_own_technician on public.spare_handover_items for select
  using (
    exists (
      select 1 from public.spare_handovers h
      where h.id = public.spare_handover_items.handover_id
        and h.technician_id = public.current_technician_id()
    )
  );

-- confirm_spare_handover: security invoker -> security definer (see header for why). Body is
-- otherwise byte-for-byte the live function from 20260702120000_technician_phase7_functions.sql.
create or replace function public.confirm_spare_handover(
  p_handover_id uuid,
  p_tech_sign_url text,
  p_admin_sign_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'confirm_spare_handover: caller is not a technician';
  end if;
  if nullif(p_tech_sign_url, '') is null or nullif(p_admin_sign_url, '') is null then
    raise exception 'confirm_spare_handover: both technician and admin signatures are required';
  end if;

  update public.spare_handovers
    set tech_sign_url = p_tech_sign_url, admin_sign_url = p_admin_sign_url, status = 'confirmed'
    where id = p_handover_id and technician_id = v_tech_id;

  if not found then
    raise exception 'confirm_spare_handover: handover % not found for this technician', p_handover_id;
  end if;
end;
$$;

revoke all on function public.confirm_spare_handover(uuid, text, text) from public, anon, authenticated;
grant execute on function public.confirm_spare_handover(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
