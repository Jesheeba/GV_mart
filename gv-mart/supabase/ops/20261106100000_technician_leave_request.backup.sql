-- Before/after backup snapshot for 20261106100000_technician_leave_request.sql.
-- READ-ONLY. Run once before GO APPLY and once after; diff the two outputs by eye.
--
-- Covers every table/function the migration touches that already exists beforehand:
--   - public.technician_availability (gets two new nullable/defaulted columns; fingerprinted
--     on technician_id/date/status only -- the same three columns the GO APPLY script's own
--     post-check uses, because those are exactly what must NOT change)
--   - public.settings (gets two new defaulted columns; fingerprinted on org_id only -- ADD
--     COLUMN does not touch existing column values, so a row-count + org_id check is enough to
--     confirm no row was added/removed/reordered; the new columns' presence and default are
--     already asserted separately by the GO APPLY script's own post-checks)
--   - public.reward_candidates(uuid,date) -- the one pre-existing function this migration
--     redefines; its full current body and an md5 of it, for a byte-exact before/after compare
--
-- public.technician_leave_requests does not exist before the migration, so it is deliberately
-- NOT referenced here (referencing a table that does not exist yet would make this script fail
-- to even parse when run "before"). After the apply, if you also want its row count, run this
-- one extra line by itself:
--   select count(*) from public.technician_leave_requests;
select
  (select count(*) from public.technician_availability) as technician_availability_count,
  (select coalesce(
     md5(string_agg(technician_id::text || ':' || date::text || ':' || status, ',' order by technician_id, date)),
     ''
   ) from public.technician_availability) as technician_availability_fingerprint,
  (select count(*) from public.settings) as settings_count,
  (select coalesce(
     md5(string_agg(org_id::text, ',' order by org_id)),
     ''
   ) from public.settings) as settings_org_id_fingerprint,
  (select md5(pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure))) as reward_candidates_def_md5,
  (select pg_get_functiondef('public.reward_candidates(uuid,date)'::regprocedure)) as reward_candidates_def_text;
