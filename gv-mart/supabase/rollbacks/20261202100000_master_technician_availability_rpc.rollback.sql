-- Rollback for 20261202100000_master_technician_availability_rpc.sql.
-- Purely additive migration (three new functions, nothing else touched) --
-- rollback is a plain drop, nothing to restore.

drop function if exists public.get_technician_availability_for_date(uuid, date, uuid);
drop function if exists public._free_gaps(time, time, jsonb);
drop function if exists public._tech_day_busy_windows(uuid, date);
