# gst-inclusive-toggle (F2) — BUILT, migration not applied

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

## As built (2026-11-26)
- Per-bill switch: New Sale (summary panel) and New Quotation, via the shared `GstModeToggle`. A quotation's choice carries into the sale when it's converted.
- Technician on-site service invoice / AMC and rentals use the **org default only**. Their RPC signatures and the offline-queue payload stay unchanged, and field staff don't get a tax switch. This deviates from D2's "service invoice, AMC" wording and is flagged to the owner.
- `quotations.gst_inclusive` is **nullable**: NULL = quotation made before this feature, printed exactly as before (no GST lines). This avoids changing the totals on quotes already sent.
- Admin `sell_amc_plan` and customer `renew_amc_plan` charge **no GST at all** (pre-existing, unlike `sell_amc_plan_onsite`). Out of scope, flagged.
- Migration `20261226110000_gst_inclusive_toggle.sql` was generated from the live function text (`_local_only/rehearsal-files/gen_gst_migration.py`). Diff vs live = GST lines only. Baseline md5s are in the header and must match at apply time.
- **Do not merge before apply**: `create_quotation` is called with the new `p_gst_inclusive` argument.
