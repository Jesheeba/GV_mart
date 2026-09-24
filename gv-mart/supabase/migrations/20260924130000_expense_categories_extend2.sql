-- Accounts/Expenses (money-out) — additional expense categories, part of the
-- same 2026-09-24 change request as 20260924120000. 'purchase' already
-- covers vendor/supplier bill payments (create_bill_entry() RPC) — kept
-- as-is, just documented here for clarity, not renamed (renaming would
-- break every existing row's semantics for no benefit).
alter type expense_category add value if not exists 'parking';
alter type expense_category add value if not exists 'ad_campaign';
alter type expense_category add value if not exists 'video_generation';
