-- Phase 5 (ADM-05..08): Sales & invoicing — schema additions.
--
-- Kept in its own file (transaction) because it adds a new `ticket_type`
-- enum value — Postgres will not let a later statement in the SAME
-- transaction reference a brand-new enum label, so the RPCs that use
-- 'installation' live in the next migration file instead.

-- A product-sale "installation" job is neither a paid repair, a warranty
-- visit, nor an AMC visit — it's the initial setup at time of sale. Phase 6's
-- "auto-detect type from warranty/amc" logic (Design Deltas §19) needs a
-- distinct value so an installation ticket is never mistaken for a repair.
alter type ticket_type add value if not exists 'installation';

-- Phase 4's Masters prompt (BuildSpec §5) called for "warranty defaults" as
-- a master field but no column ever landed for it. Product Sale (ADM-06)
-- needs a default warranty length to propose at the Warranty step — modeled
-- per-product (not a single global default) since RO/AC/inverter/battery
-- warranty periods genuinely differ. Admin-editable via Masters, per the
-- "no hardcoded business figures" rule already applied to every other
-- number in this schema.
alter table products add column warranty_months integer not null default 12 check (warranty_months > 0);

-- `invoices.gst` has existed since Phase 1 with no rate to compute it from.
-- v2.2 explicitly rules out a GST-filing checklist, but a basic org-wide
-- rate is still needed to produce the with-GST/without-GST invoice totals
-- ADM-07 requires. One rate for the whole org (not per-item) keeps this to
-- the minimum needed for Phase 5; admin-editable, matching every other
-- settings figure.
alter table settings add column gst_rate numeric(5, 2) not null default 18 check (gst_rate >= 0 and gst_rate <= 100);

-- Traceability back to the sale that generated each record — ADM-07's
-- invoice view needs to show "this invoice created warranty X / ticket Y /
-- AMC contract Z", which is otherwise unrecoverable (none of these tables
-- had an invoice_id before Phase 5, since none of them existed at sale time
-- until now).
alter table warranties add column invoice_id uuid references invoices (id) on delete set null;
alter table service_tickets add column invoice_id uuid references invoices (id) on delete set null;
alter table amc_contracts add column invoice_id uuid references invoices (id) on delete set null;

create index warranties_invoice_id_idx on warranties (invoice_id) where invoice_id is not null;
create index service_tickets_invoice_id_idx on service_tickets (invoice_id) where invoice_id is not null;
create index amc_contracts_invoice_id_idx on amc_contracts (invoice_id) where invoice_id is not null;

-- Phase 4's audit convention (write-up in 20260702090000_audit_triggers.sql)
-- only covered masters. Sales actions are equally sensitive (money +
-- service commitments) and belong in the same trail.
create trigger audit_invoices after insert or update or delete on invoices for each row execute function public.audit_master_change();
create trigger audit_quotations after insert or update or delete on quotations for each row execute function public.audit_master_change();
create trigger audit_warranties after insert or update or delete on warranties for each row execute function public.audit_master_change();
create trigger audit_amc_contracts after insert or update or delete on amc_contracts for each row execute function public.audit_master_change();
create trigger audit_service_tickets after insert or update or delete on service_tickets for each row execute function public.audit_master_change();
