-- Expense/Accounts tracking — money out (salaries, rent, EB, general expenses)
-- change request, authorized 2026-09-24, against the v2.2 scope guard's
-- "bank-payment-tracking screen" item (GV_Mart_ClaudeCode_BuildSpec.md:26,
-- GV_Mart_Design_Deltas_for_ClaudeDesign.md:103).
--
-- Scope: extends the existing `expenses` table + a new Accounts/Expenses
-- admin UI to record and report business costs actually paid out (salary,
-- rent, EB, other). Explicitly excludes anything the guard covers: no
-- bank_accounts table, no reconciliation against bank statements, no bank
-- transaction matching, no multi-bank-account management. This is a ledger
-- of what the business spent, not what any bank account received or holds —
-- same distinction the UPI QR payment change request drew when it was
-- authorized against this guard item on 2026-08-06
-- (20260806090000_payment_method_add_upi.sql).

-- New expense_category values — 'rent' and 'electricity' previously had no
-- home and would have been misfiled under 'other'.
alter type expense_category add value if not exists 'rent';
alter type expense_category add value if not exists 'electricity';
