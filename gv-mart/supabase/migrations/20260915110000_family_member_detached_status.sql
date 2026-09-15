-- Item D3: "Move to new customer" was a hard create-then-delete — the
-- original customer_members row vanished with no trace once a family member
-- was split into their own customer record. Adds a soft "detached" marker
-- instead, preserving history; getCustomer's embedded customer_members
-- fetch filters these out so every existing consumer (Family tab count,
-- FamilyMembersPanel's list, the D9 family chip) keeps seeing only active
-- members without needing its own filter.
alter table public.customer_members add column if not exists moved_out_at timestamptz;
