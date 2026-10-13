-- Rollback for 20261018160000_automation_handoff_amc_ref_type.sql: AMC subjects are held (left untouched) again by the hand-off.
-- Outbox rows already written with ref_type 'amc_contract' stay as they are (a dispatcher without the ref type will not pick them up).
begin;
delete from public.automation_handoff_ref_types where ref_type = 'amc_contract';
commit;
