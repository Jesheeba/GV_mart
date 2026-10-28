-- Rollback for 20261107100200_expense_claims.sql
--
-- This rollback REFUSES, loudly, if there is any real data it would
-- destroy: any row in expense_claims, or any object in the
-- expense-claim-photos bucket. It never issues a DELETE against
-- storage.objects or storage.buckets anywhere in this file -- those are
-- the Storage service's own tables, and deleting from them in plain SQL
-- bypasses the Storage API's own bookkeeping (it does not reliably remove
-- the underlying object from the backing store the way the Storage API's
-- own delete call does, and can leave it orphaned).
--
-- Emptying the bucket AND removing the bucket row itself are both
-- separate, named, manual steps, outside this file entirely:
--   1. Delete every object in expense-claim-photos through the Storage
--      API or dashboard (never a plain SQL DELETE), and confirm it
--      reports empty.
--   2. Delete the expense-claim-photos bucket itself through the same
--      Storage API or dashboard (never a plain SQL DELETE on
--      storage.buckets).
-- This rollback only ever CHECKS that step 1 already happened (refusing
-- if it hasn't) and drops this feature's own tables/functions/policies --
-- it does not touch storage.objects or storage.buckets at all.
--
-- Run this as its own statement outside any wrapper (it is designed to
-- legitimately COMMIT when nothing blocks it -- this is a real rollback,
-- not a rehearsal).
begin;
do $rb_refuse_check$
declare
  v_claims int;
  v_objects int;
begin
  select count(*) into v_claims from public.expense_claims;
  if v_claims > 0 then
    raise exception 'rollback refused: % row(s) exist in expense_claims -- this rollback drops that table and does not preserve data. Export it first, or confirm the data genuinely does not need to survive, then remove those rows by hand before re-running this rollback.', v_claims;
  end if;

  select count(*) into v_objects from storage.objects where bucket_id = 'expense-claim-photos';
  if v_objects > 0 then
    raise exception 'rollback refused: % object(s) still exist in the expense-claim-photos bucket -- empty it through the Storage API/UI first (never via a plain DELETE against storage.objects in SQL), confirm it reports empty, then re-run this rollback.', v_objects;
  end if;
end
$rb_refuse_check$;

revoke execute on function public.submit_expense_claim(uuid, text, numeric, text, date) from authenticated;
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from authenticated;
drop function if exists public.submit_expense_claim(uuid, text, numeric, text, date);
drop function if exists public.verify_expense_claim(uuid, numeric, text);
drop function if exists public.technician_expense_claims_total(uuid, uuid, date, text);
drop policy if exists expense_claim_photos_storage_insert on storage.objects;
drop policy if exists expense_claim_photos_storage_select on storage.objects;
-- The expense-claim-photos bucket row itself is NOT dropped here -- that
-- is step 2 of the documented manual process above, done through the
-- Storage API/dashboard, never a SQL DELETE on storage.buckets.
drop trigger if exists audit_expense_claims on public.expense_claims;
drop policy if exists expense_claims_select_staff on public.expense_claims;
drop policy if exists expense_claims_select_own on public.expense_claims;
drop index if exists public.expense_claims_org_id_idx;
drop index if exists public.expense_claims_technician_id_idx;
drop index if exists public.expense_claims_period_idx;
drop table if exists public.expense_claims;
commit;
notify pgrst, 'reload schema';
