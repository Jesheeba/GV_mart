-- Automation Phase 3 / Stage B, dispatcher side: the hand-off may now write outbox rows for AMC contracts.
--
-- Goes together with the Edge Function change in the SAME commit (wa-milestone-dispatch-core.ts: MILESTONE_REF_TYPES gains
-- 'amc_contract'; wa-event-context.ts resolves product, plan, expiry and visit date for it). Apply this migration ONLY after
-- those functions are deployed: a pending 'amc_contract' row the deployed dispatcher does not know would never be picked up.
-- It changes nothing else: a one-row insert into the hand-off whitelist, no function body, no schema.
insert into public.automation_handoff_ref_types (ref_type, subject_type)
values ('amc_contract', 'amc_contract')
on conflict (ref_type) do nothing;
