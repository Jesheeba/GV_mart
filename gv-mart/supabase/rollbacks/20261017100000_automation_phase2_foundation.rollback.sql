-- Rollback for 20261017100000_automation_phase2_foundation.sql
-- Removes the emit triggers first (so no business statement can reach automation_emit), then the engine, then the tables.
-- Data in the six automation_* tables is DESTROYED (event log, audit, queue are dry-run records only; nothing was sent).
-- The settings.automation_enabled column is dropped too.
begin;
drop trigger if exists zz_automation_emit_ticket    on public.service_tickets;
drop trigger if exists zz_automation_emit_visit     on public.service_visits;
drop trigger if exists zz_automation_emit_invoice   on public.invoices;
drop trigger if exists zz_automation_emit_lead      on public.leads;
drop trigger if exists zz_automation_emit_amc       on public.amc_contracts;
drop trigger if exists zz_automation_emit_warranty  on public.warranties;
drop trigger if exists zz_automation_emit_quotation on public.quotations;
drop function if exists public._trg_automation_emit_ticket();
drop function if exists public._trg_automation_emit_visit();
drop function if exists public._trg_automation_emit_invoice();
drop function if exists public._trg_automation_emit_lead();
drop function if exists public._trg_automation_emit_amc();
drop function if exists public._trg_automation_emit_warranty();
drop function if exists public._trg_automation_emit_quotation();
drop function if exists public.automation_rule_save(uuid, text, text, text, jsonb, text, text, integer, integer, integer, text, uuid, text);
drop function if exists public.automation_emit(uuid, text, text, uuid, uuid, text, jsonb);
drop function if exists public._automation_conditions_match(jsonb, jsonb);
drop function if exists public._automation_log_error(uuid, text, text, text, uuid, text, text);
-- the append-only triggers refuse DELETE/TRUNCATE; DROP TABLE removes the triggers with the table
drop table if exists public.automation_errors;
drop table if exists public.automation_queue;
drop table if exists public.automation_audit;
drop table if exists public.automation_event_log;
drop table if exists public.automation_rules;
drop table if exists public.automation_flow_defs;
drop table if exists public.automation_events;
drop function if exists public._trg_automation_rules_immutable();
drop function if exists public._trg_automation_append_only();
alter table public.settings drop column if exists automation_enabled;
commit;
