-- Rollback for 20261025200000_wa_initiated_allowlist_gate.sql.
--
-- Order matters: the trigger first, then its function, then the column.
-- Deploy order on rollback: redeploy the functions that do not read the column FIRST (or leave them; they fail closed and
-- block every initiated send while the column is gone), then run this file.
-- No other object is touched. Data in the column is discarded; the flag defaults to true again if the migration is re-applied.

drop trigger if exists settings_wa_initiated_guard on public.settings;

drop function if exists public._trg_settings_wa_initiated_guard();

alter table public.settings drop column if exists wa_initiated_allowlist_only;
