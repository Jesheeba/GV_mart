-- Rollback for 20261107100300_person_allowances_and_adjustments.sql
-- Drops the four read functions, both tables (triggers/policies/indexes go
-- with them), and the settings.own_bike_allowance_base column. No new
-- audit trigger was added for that column (it rides settings' existing
-- audit_settings trigger), so there is nothing extra to drop for it besides
-- the column itself.
begin;
revoke execute on function public.person_allowance_on(uuid, uuid, date) from authenticated;
revoke execute on function public.monthly_adjustment_top_up(uuid, uuid, date, text) from authenticated;
revoke execute on function public.monthly_adjustment_excluded(uuid, uuid, date, text) from authenticated;
drop function if exists public.person_allowance_on(uuid, uuid, date);
drop function if exists public.monthly_adjustment_top_up(uuid, uuid, date, text);
drop function if exists public.monthly_adjustment_excluded(uuid, uuid, date, text);
drop trigger if exists audit_person_allowances on public.person_allowances;
drop trigger if exists audit_monthly_adjustments on public.monthly_adjustments;
drop policy if exists person_allowances_select_ops on public.person_allowances;
drop policy if exists person_allowances_write_ops on public.person_allowances;
drop policy if exists monthly_adjustments_select_ops on public.monthly_adjustments;
drop policy if exists monthly_adjustments_write_ops on public.monthly_adjustments;
drop index if exists public.person_allowances_org_id_idx;
drop index if exists public.person_allowances_profile_id_idx;
drop index if exists public.monthly_adjustments_org_id_idx;
drop index if exists public.monthly_adjustments_lookup_idx;
drop table if exists public.monthly_adjustments;
drop table if exists public.person_allowances;
alter table public.settings drop column if exists own_bike_allowance_base;
commit;
notify pgrst, 'reload schema';
