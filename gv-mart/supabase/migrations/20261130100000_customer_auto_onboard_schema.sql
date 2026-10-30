-- Schema for auto-onboarding a customer on first Google sign-in. Additive only, plus one
-- necessary relaxation (customers.mobile NOT NULL -> nullable, see below).
--
-- customers.email: NEW. Nullable, loose format check (same shape as the existing
-- customer_members.email check from 20261012110000_customer_member_email.sql). This is the ONLY
-- column customer_auto_onboard() (next migration) matches a Google sign-in's email against --
-- never customer_members.email, which is a family member's own optional email, not the account
-- holder's.
--
-- customers.needs_review / needs_review_reason: NEW. Set when auto-onboarding had to create a
-- new customer instead of linking because the email match was ambiguous (more than one existing
-- customer with that email) or because the one match it found was already linked to a different
-- Google sign-in -- never guessed at in either case. Surfaced to master/ops as a badge (frontend,
-- same migration's sibling PR).
--
-- customers.mobile: relaxed from NOT NULL to nullable. A customer created by Google
-- auto-onboarding has no phone number at all until they provide one later (spec: "Phone: DO NOT
-- match on a phone number the user typed" -- phone-based linking stays the existing OTP flow's
-- job, flag OFF). The pre-existing format check (20260819100000_customer_mobile_format_constraint.sql,
-- `mobile ~ '^\d{10}$'`) already tolerates NULL unmodified -- in Postgres, `NULL ~ pattern`
-- evaluates to NULL, and a CHECK constraint only fails on an explicit `false`, never on NULL --
-- so no change to that constraint is needed or made. Confirmed no UNIQUE constraint/index
-- involves mobile (only the non-unique `customers_mobile_idx (org_id, mobile)`), so multiple
-- NULLs in the same org are unaffected either way.
--
-- Exhaustive audit (2026-11-30, re-run after an owner challenge to the first pass) of every
-- `customers.mobile` read/write across SQL functions/views/triggers/policies, Edge Functions and
-- the TS/TSX frontend. DB-side identify/match lookups (`wa_identify_customer`, the WA outbound
-- allow-list, lead-notification identify, `_mobile_key`) are all equality comparisons against a
-- real phone -- `NULL = x` is never true, so a mobile-less customer is correctly "not found",
-- never a crash. Frontend: JSX interpolation (`{x.mobile}`) renders nothing for null, already
-- safe everywhere. Found and fixed, same PR as this migration:
--   - CustomerDetailPage.tsx's WhatsApp-link derivation (the one found in the first pass).
--   - Two WhatsApp scheduled-task sends (supabase/functions/wa-scheduled-tasks/index.ts,
--     AMC reminders + feedback requests) that guarded "no customer row" but not "no mobile" --
--     would have tried to send to a null destination for any auto-onboarded customer with an
--     AMC contract or completed ticket. Now skip when mobile is null, same as "no customer".
--   - 8 customer-picker label template literals across 6 admin pages (SellAmcPanel,
--     LeadDetailPanel, QuotationFormPage, RentOutPanel, NewComplaintPage x2, NewSalePage x3)
--     that stringified a null mobile as the literal text "null" (template-literal
--     interpolation, unlike JSX, does not render null as nothing). Now show the name alone when
--     mobile is null.
--   - The Customers CSV export's Mobile column, same "null"-the-literal-string issue.
alter table public.customers alter column mobile drop not null;

alter table public.customers add column email text;
alter table public.customers add constraint customers_email_format
  check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.customers add column needs_review boolean not null default false;
alter table public.customers add column needs_review_reason text;

-- source already has a fitting enum value for this -- lead_source.'customer_app'
-- (20260701090000_extensions_and_enums.sql) -- no new enum value or column needed; the RPC uses
-- that value verbatim for every customer it creates.

-- customers.auto_link_blocked_at / auto_link_blocked_by: NEW. Set by
-- admin_unlink_customer_google_account (redefined in 20261130100002) when a master unlinks a
-- customer's Google sign-in. Prevents the "unlink loop": without this, the very next sign-in by
-- that same Google account would hit customer_auto_onboard(), see the customer unlinked again,
-- and silently re-link it right back -- defeating the master's unlink entirely. Cleared only by
-- a master successfully re-linking the SAME customer via admin_link_customer_google_account
-- (also redefined in 20261130100002) -- an explicit master action, never automatically.
alter table public.customers add column auto_link_blocked_at timestamptz;
alter table public.customers add column auto_link_blocked_by uuid references public.profiles (id) on delete set null;
