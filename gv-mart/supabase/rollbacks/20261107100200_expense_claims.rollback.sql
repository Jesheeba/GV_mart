-- Rollback for 20261107100200_expense_claims.sql
-- Drops the two write RPCs and the one read function, the storage policies,
-- the audit trigger, both select policies, the indexes and the table.
-- Also deletes every object in and then the expense-claim-photos bucket
-- itself -- uploaded bill photographs are not preserved by this rollback.
-- Export the bucket's contents first if any photo has to survive.
begin;
revoke execute on function public.submit_expense_claim(uuid, text, numeric, text, date) from authenticated;
revoke execute on function public.verify_expense_claim(uuid, numeric, text) from authenticated;
revoke execute on function public.technician_expense_claims_total(uuid, uuid, date, text) from authenticated;
drop function if exists public.submit_expense_claim(uuid, text, numeric, text, date);
drop function if exists public.verify_expense_claim(uuid, numeric, text);
drop function if exists public.technician_expense_claims_total(uuid, uuid, date, text);
drop policy if exists expense_claim_photos_storage_insert on storage.objects;
drop policy if exists expense_claim_photos_storage_select on storage.objects;
delete from storage.objects where bucket_id = 'expense-claim-photos';
delete from storage.buckets where id = 'expense-claim-photos';
drop trigger if exists audit_expense_claims on public.expense_claims;
drop policy if exists expense_claims_select_staff on public.expense_claims;
drop policy if exists expense_claims_select_own on public.expense_claims;
drop index if exists public.expense_claims_org_id_idx;
drop index if exists public.expense_claims_technician_id_idx;
drop index if exists public.expense_claims_period_idx;
drop table if exists public.expense_claims;
commit;
notify pgrst, 'reload schema';
