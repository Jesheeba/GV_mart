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
-- so no change to that constraint is needed or made. Audited every `.mobile` call site in src/
-- for a null-unsafe access: exactly one found (CustomerDetailPage.tsx's WhatsApp link), fixed in
-- the same PR as this migration.
alter table public.customers alter column mobile drop not null;

alter table public.customers add column email text;
alter table public.customers add constraint customers_email_format
  check (email is null or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

alter table public.customers add column needs_review boolean not null default false;
alter table public.customers add column needs_review_reason text;

-- source already has a fitting enum value for this -- lead_source.'customer_app'
-- (20260701090000_extensions_and_enums.sql) -- no new enum value or column needed; the RPC uses
-- that value verbatim for every customer it creates.
