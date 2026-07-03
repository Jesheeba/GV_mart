-- Phase 6 (ADM-09..13): Service, scheduling, AMC/Warranty — schema additions.
--
-- Kept separate from the functions migration (110100) purely for readability
-- (schema vs. behaviour), same convention as Phase 5's 100000/100100 split.

-- ── SLA duration per priority (ADM-09 "live SLA countdown from sla_due_at") ─
-- `service_tickets.sla_due_at` has existed since Phase 1 but nothing ever
-- set it — v2.2 §6.4 defines priority (very_urgent/urgent/normal) but gives
-- no SLA-hours figure, so per the "no hardcoded business figures" rule
-- (system.sql) these three durations are admin-editable settings, not
-- constants in application code. Sensible defaults: very urgent same-shift,
-- urgent same-day-ish, normal a couple of days.
alter table settings
  add column sla_hours_very_urgent numeric(6, 2) not null default 4 check (sla_hours_very_urgent > 0),
  add column sla_hours_urgent numeric(6, 2) not null default 24 check (sla_hours_urgent > 0),
  add column sla_hours_normal numeric(6, 2) not null default 48 check (sla_hours_normal > 0);

-- ── Completed-job report fields (Design Deltas §23 / BuildSpec ADM-09 ticket
-- detail: "appointment date & time, service start time, service close time,
-- total time taken"). `service_visits.timer_start/timer_end` already cover
-- start/close; `total time taken` is a pure derived value (end - start) so
-- it's computed in the UI/service layer, not stored redundantly.

-- ── Repeat-complaint flag (ADM-09) ──────────────────────────────────────
-- "repeat-complaint" is derived (>1 ticket for the same customer+product
-- within a lookback window) — no new column needed, computed in services/.

-- ── Audit triggers for tables that don't have one yet ───────────────────
-- 20260702090000_audit_triggers.sql covered masters; 20260702100000 covered
-- sales tables incl. service_tickets. appointments/service_visits/
-- amc_contracts (already covered)/ro_checklists/service_spares_used are
-- Phase 6 territory and still need one. `warranties`/`amc_contracts`/
-- `service_tickets` already have triggers from Phase 5 — not repeated here.
create trigger audit_appointments after insert or update or delete on appointments for each row execute function public.audit_master_change();
create trigger audit_service_visits after insert or update or delete on service_visits for each row execute function public.audit_master_change();
create trigger audit_service_spares_used after insert or update or delete on service_spares_used for each row execute function public.audit_master_change();
create trigger audit_ro_checklists after insert or update or delete on ro_checklists for each row execute function public.audit_master_change();
