-- Cost/margin tracking, stage 1 (structure only — see build report for the
-- "check first" findings this extends rather than duplicates).
--
-- Owner request: the system can currently show revenue but not profit —
-- products/spares/gifts only ever carried a sale `price`, no cost basis.
-- Real cost data for existing catalog items is still on its way from the
-- owner (Excel, not yet received), so every column here is NULLABLE and
-- every column that follows on invoice_items/gift_logs is a snapshot that
-- stays null until an item's cost_price is actually set — never fabricated,
-- never defaulted to 0 (0 would silently read as "free to acquire").

alter table public.products add column cost_price numeric(12, 2) check (cost_price is null or cost_price >= 0);
alter table public.spares add column cost_price numeric(12, 2) check (cost_price is null or cost_price >= 0);
alter table public.gifts add column cost_price numeric(12, 2) check (cost_price is null or cost_price >= 0);

-- Snapshot, not a live join to products/spares.cost_price: cost_price is a
-- "latest price paid" value that moves forward over time (owner decision),
-- so a past invoice's reported profit must not silently change later when
-- this month's purchase price changes. Null when the item had no cost_price
-- set yet at the moment of sale.
alter table public.invoice_items add column cost numeric(12, 2) check (cost is null or cost >= 0);

-- Same snapshot reasoning for gifts given away — pure cost, no matching
-- revenue line anywhere else (gifts never appear in invoice_items).
alter table public.gift_logs add column cost numeric(12, 2) check (cost is null or cost >= 0);
