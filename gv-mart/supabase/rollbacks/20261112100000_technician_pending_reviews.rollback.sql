-- Rollback for 20261112100000_technician_pending_reviews.sql. Purely additive migration (one new function, no
-- table/column/RLS change), so the rollback is just dropping it.
begin;
drop function if exists public.list_technician_pending_reviews();
commit;
