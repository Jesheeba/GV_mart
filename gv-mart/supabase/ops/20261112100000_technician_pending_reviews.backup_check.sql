-- Backup/diagnostic read for migration 20261112100000_technician_pending_reviews.sql.
--
-- READ-ONLY -- no DO block, no DDL/DML, nothing written. Plain SELECTs only, safe to run at any time
-- (before or after the apply script) to capture a point-in-time snapshot for the backup record.
--
-- Covers:
--   * row counts and an order-stable md5 fingerprint for each table
--     public.list_technician_pending_reviews() reads (service_visits, service_tickets, customers,
--     ratings) -- the same four tables the rehearsal wrapper's own real-row fingerprint is built from.
--     The migration itself does not write to any of these tables (it only creates a function and
--     changes its grants), so these are expected to be identical before and after a correct apply.
--   * the current live definition of every function this migration redefines
--     (public.list_technician_pending_reviews() -- expected NULL/no rows before the apply, and the
--     full CREATE OR REPLACE FUNCTION text after it).

-- Row counts.
select
  (select count(*) from public.service_visits)   as service_visits_count,
  (select count(*) from public.service_tickets)  as service_tickets_count,
  (select count(*) from public.customers)        as customers_count,
  (select count(*) from public.ratings)          as ratings_count;

-- Order-stable md5 fingerprint per table (md5 of every row's own md5, concatenated in primary-key order
-- so the result is reproducible and independent of physical row order).
select 'service_visits' as table_name,
  md5(coalesce(string_agg(md5(sv.*::text), ',' order by sv.id), '')) as fingerprint
from public.service_visits sv
union all
select 'service_tickets',
  md5(coalesce(string_agg(md5(t.*::text), ',' order by t.id), ''))
from public.service_tickets t
union all
select 'customers',
  md5(coalesce(string_agg(md5(c.*::text), ',' order by c.id), ''))
from public.customers c
union all
select 'ratings',
  md5(coalesce(string_agg(md5(r.*::text), ',' order by r.id), ''))
from public.ratings r;

-- Current live definition of every function this migration redefines. Expected: zero rows (the function
-- does not exist yet) before a first-ever apply; one row with the full CREATE OR REPLACE FUNCTION text
-- after a successful apply.
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_functiondef(p.oid) as live_definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'list_technician_pending_reviews';
