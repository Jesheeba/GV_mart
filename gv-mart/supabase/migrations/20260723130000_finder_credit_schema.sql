-- STEP 6.3 (Assignment spec Phase 5.1) — Finder credit payout, schema half.
--
-- GROUND-TRUTH CORRECTION vs the Build Order text ("leads.owner_id is now
-- set and shown on the report"): owner_id IS already written today, just not
-- by a new mechanism — generate_enquiry_lead (TECH-07 "Generate Enquiry",
-- 20260702120000_technician_phase7_functions.sql) already inserts leads with
-- owner_id = current_technician_id() when a technician logs a field
-- enquiry, and is wired end-to-end (OnSiteVisitPage -> useGenerateEnquiry ->
-- offline sync's "lead.generate" job -> this RPC). What was genuinely
-- missing (confirmed by grep) is (a) any linkage from a converted lead back
-- to the service_tickets row it produced, and (b) any use of owner_id in the
-- incentive engine. This migration adds (a); the next migration
-- (20260723131000) wires (b) plus the traceability into create_sale.
--
-- Kept in its own file/transaction: this also adds a new incentive_type
-- enum value, and Postgres will not let a later statement in the SAME
-- transaction reference a brand-new enum label (see precedent at
-- 20260702100000_sales_phase5_schema.sql's `ticket_type` addition) — so the
-- compute_incentives branch that uses 'finder_credit' lives in the next file.

-- Traceability: a ticket produced by a converted lead can be traced back to
-- it. Nullable — most tickets (walk-in, repeat customer, WhatsApp) have no
-- lead at all. Populated by create_sale in the next migration, the only
-- place in the schema that turns a lead (via quotations.lead_id, added in
-- 20260701090900_leads_automation.sql) into service_tickets rows today.
alter table public.service_tickets add column if not exists lead_id uuid references public.leads (id) on delete set null;

create index if not exists service_tickets_lead_id_idx on public.service_tickets (lead_id) where lead_id is not null;

-- New incentive type so a finder-credit rule can sit in the same
-- admin-configurable incentive_rules master as service_income/sales_income/
-- review (Masters > Incentives) — no hardcoded ₹ rate here, matching this
-- table's existing "every rate is admin-set" convention. The owner still
-- needs to set threshold/amount for this rule via that screen (see the
-- build report note) — this only adds the mechanism.
alter type public.incentive_type add value if not exists 'finder_credit';
