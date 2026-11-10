-- Rollback for 20261203100000_master_technician_availability_rpc.sql.
-- (Renumbered 2026-11-02 from 20261202100000, which collided with an
-- already-registered, unrelated migration of the same version
-- ("referral_bonus_schema") -- never reuse or edit a registered version.)
-- Purely additive migration (three new functions, nothing else touched) --
-- rollback is a plain drop, nothing to restore.

drop function if exists public.get_technician_availability_for_date(uuid, date, uuid);
drop function if exists public._free_gaps(time, time, jsonb);
drop function if exists public._tech_day_busy_windows(uuid, date);
