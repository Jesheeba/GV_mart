-- Item D2: "profession" existed only on customers (the primary member's own
-- row) — customer_members (family members) had no equivalent column at any
-- layer (DB, types, or UI). Real gap, not a UI oversight; add the column.
alter table public.customer_members add column if not exists profession text;
