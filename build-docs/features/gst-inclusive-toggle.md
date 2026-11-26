# gst-inclusive-toggle (F2) — DESIGN, awaiting D2

**Purpose:** let staff bill a price as "GST included" (₹12,500 is the final price) or "GST extra" (₹12,500 + 18%).

**Architecture (recommended)**
- `settings.prices_include_gst boolean default false` (org default, Masters → Settings).
- Per-bill toggle "GST: Included / Extra" on New Sale, Service invoice, AMC sell, Quotation; starts at the org default.
- Math (inclusive): taxable = (subtotal − discount) / (1 + r); gst = (subtotal − discount) − taxable; total = subtotal − discount. Exclusive unchanged.
- `invoices.gst_inclusive boolean` + `quotations.gst_inclusive` stored so print/reports show the right split.
- RPCs take `p_gst_inclusive boolean default null` (null → org default): `_sale_create_line_invoice`, `create_sale`, `create_service_invoice`, `sell_amc_plan_onsite`, `create_rental`, `run_rental_billing` (uses org default only).
- `sale-calc.ts billBreakdown(subtotal, disc, rate, inclusive)` mirrors SQL.

**Impact map:** 6 RPCs (DROP+recreate signatures → re-GRANT EXECUTE, see MEMORY Postgres gotcha), invoices/quotations tables, database.ts hand-patch, SaleSummaryPanel, NewSalePage, service invoice page, SellAmcPanel, QuotationForm/Detail, InvoicePage print, reports "of which GST" (reads invoices.gst — unchanged meaning), P&L.

**Edge cases:** rate 0; 100% discount; rounding (round2 each step, same as SQL); old invoices = exclusive (column default false); referral redeem after GST; partial payments; rate change between quote and sale.

**Acceptance:** inclusive ₹11,800 @18% → taxable 10,000.00, GST 1,800.00, total 11,800.00; exclusive unchanged for existing tests; RPC and client agree to the paisa; printed invoice labels mode; grants unchanged before/after.
