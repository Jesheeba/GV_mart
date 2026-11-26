# gst-inclusive-toggle (F2) — LIVE 2026-11-26

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
- Applied 2026-11-26 after md5 check (all 7 matched). ACLs identical to before. Existing data unchanged (1 invoice stays Extra, 4 quotations stay NULL, org default off).

## gst-everywhere follow-up (2026-11-26, owner: "fix them all" + "Create GST invoice")
- **Bug found:** the technician on-site screen showed and collected the total *without* GST, while `create_service_invoice` added 18%. The QR and cash amounts were short of the invoice. The same applied to the on-site "Sell AMC for ₹X" button. Both now use `billBreakdown`.
- Per-bill GST switch added for technician on-site invoice + AMC, Rent Out (stored on `rental_contracts.gst_inclusive`, which the monthly cron uses) and admin Sell AMC. Shared `GstSummary` component.
- Admin `sell_amc_plan` now bills an `amc` invoice and asks for the payment method (transfer needs a txn id and description). The referrer wrapper passes it through.
- Customer `renew_amc_plan` now bills an `amc` invoice at the org default. The app's payment step is **simulated**, so the invoice is **due** (reference kept in `txn_id`); no fake revenue. `get_customer_app_settings` exposes `gst_rate` + `prices_include_gst` for the renewal total.
- All new params default NULL → org default, so offline jobs already queued on phones and older app builds keep working. `gstInclusive` is not a required outbox field.
- Migration `20261230100000_gst_everywhere.sql` was generated from live text by `_local_only/rehearsal-files/gen_gst_everywhere.mjs`; the rollback file is next to it. Baseline md5s (8 functions) matched 2026-11-26.
- Impact: invoices insert triggers (referral points on paid, milestone notify, automation emit) now also fire for admin and customer AMC sales, the same as for on-site AMC.
