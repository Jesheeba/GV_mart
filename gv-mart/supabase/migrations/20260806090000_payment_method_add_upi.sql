-- QR Payment + Gated Completion Code (change request, authorized 2026-08-05
-- against the v2.2 scope guard's "bank-payment-tracking screen" item — see
-- the plan's Context section for the full authorization trail).
--
-- Adds 'upi' as a third payment_method alongside the existing 'cash'/
-- 'transfer' (20260701090000_extensions_and_enums.sql). Must be its own
-- migration/transaction: Postgres forbids using a newly added enum value in
-- the same transaction that adds it, and every later migration in this
-- feature references 'upi' in a function body.
alter type payment_method add value 'upi';
