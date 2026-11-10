-- Backup-first step for the customer_auto_onboard apply (no Supabase dashboard involved -- this
-- runs through the same Management API single-query runner, run_rehearsal.mjs, as every other
-- step in this pipeline). Run this BEFORE the real apply and save its .out.txt somewhere durable
-- (GV_mart\_local_only\reports\customer_auto_onboard\backup_<timestamp>.json) -- that file IS
-- the backup.
--
-- What's actually at risk and why this is enough: every column this migration chain adds is new
-- (email, needs_review, needs_review_reason, auto_link_blocked_at, auto_link_blocked_by,
-- archived_at, archived_by) -- there is nothing pre-existing in them to lose. The one change to
-- an EXISTING column is customers.mobile NOT NULL -> nullable, which touches no row's actual
-- value. So the only real "what could this migration lose" surface is: every customer's current
-- (id, org_id, primary_profile_id, mobile) and every profile's current (id, org_id, role) --
-- exactly what's captured below, for every REAL (non-__TEST_) row. If anything ever needs
-- reverting beyond what the rollback script (supabase/rollbacks/20261130100000_customer_auto_onboard.rollback.sql)
-- already undoes structurally, this is the row-level data to restore from.
select
  (select jsonb_agg(jsonb_build_object('id', c.id, 'org_id', c.org_id, 'primary_profile_id', c.primary_profile_id, 'mobile', c.mobile) order by c.id)
     from public.customers c
    where c.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\')) as customers_backup,
  (select jsonb_agg(jsonb_build_object('id', p.id, 'org_id', p.org_id, 'role', p.role) order by p.id)
     from public.profiles p
    where p.org_id not in (select id from public.organizations where name like '\_\_TEST\_%' escape '\')) as profiles_backup,
  now() as taken_at;
