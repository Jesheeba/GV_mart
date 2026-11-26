# Feature: no-gst-bill (2026-11-26)

Status: BUILT on feat/no-gst-bill. Migration 20270101100000 REHEARSED (21/21), NOT applied live; waits for the owner's "go apply".

## Purpose
- Owner: a bill can be made **without GST** (0 tax on the invoice) wherever GST is charged today.
- Flagged to the owner before building: a GST-registered shop may only bill without GST for exempt goods. Otherwise these bills can fail a GST audit. Owner chose to build it ("Real no-GST bill").

## Rule
- The per-bill GST switch gets a third choice: **GST extra | GST included | No GST**.
- No GST: GST = 0, total = price after discount. It is never the default: new bills still start from the org setting (extra/included).
- The choice is stored on the bill, so prints, reports and monthly rentals follow it.

## Where (every place staff choose GST today)
| Screen | RPC |
|---|---|
| New Sale (product, spare, AMC lines) | create_sale → _sale_create_line_invoice (cart.no_gst) |
| Quotation (carried into the sale on convert) | create_quotation (p_no_gst) |
| Rent Out + monthly rent bills | create_rental (p_no_gst, stored on rental_contracts), run_rental_billing |
| Admin Sell AMC (+ referrer wrapper) | sell_amc_plan, sell_amc_plan_with_referrer |
| Technician on-site invoice + Sell AMC | create_service_invoice, sell_amc_plan_onsite (offline queue field `noGst`, optional) |
- Out: customer-app AMC renewal (the customer doesn't choose; it stays on the org default).

## Architecture
- DB: `quotations.no_gst` and `rental_contracts.no_gst`, both `boolean not null default false`. Invoices get NO new column: GST 0 is the record, and the print shows "GST not charged" when gst = 0. Existing rows stay false.
- RPCs: a new trailing param `p_no_gst` (6 functions, drop + recreate, ACLs re-granted as live) / cart key `no_gst` (create_sale). Where it is true, rate 0 (GST 0, total = net). Default null → GST charged as before, so old app builds and queued offline jobs keep working.
- Function bodies are generated from the LIVE definitions with an md5 baseline check, like 20261230100000.
- UI: `GstModeToggle` takes a mode `"extra" | "included" | "none"`. The maths uses the existing `billBreakdown(..., rate 0)`. No new calculation code.
- Print/invoice page: when no_gst, hide the GST row and show "GST not charged".
- Reports: GST collected = sum(gst) and net = total − gst, so both stay correct with no change.

## Impact map
- The 9 RPCs above (md5-guarded). Invoice insert triggers (referral points, milestone notify, automation) are unchanged: they don't read GST.
- Shared UI: GstModeToggle, GstSummary, SaleSummaryPanel, NewSalePage, QuotationForm/Detail, RentOutPanel, SellAmcPanel, OnSiteVisitPage, SellAmcSection, InvoicePage, the offline outbox contract/sync.
- Quotation → sale conversion must carry no_gst.

## Edge cases
- An old offline job without `noGst` falls back to the org default (unchanged behaviour).
- No GST + discount: the discount applies to the price, and GST stays 0.
- An org GST rate of 0 already gives GST 0. no_gst only records that it was chosen per bill.
- Payment amount and QR on-site must use the no-GST total (same billBreakdown as the invoice).

## Acceptance criteria
1. Each screen in the table offers No GST. When chosen, the summary, saved invoice and print show GST 0 and total = net.
2. Not choosing it changes nothing: extra/included and the org default behave as before.
3. A rental made with No GST produces monthly bills with GST 0.
4. A No GST quotation converts into a No GST sale.
5. Old invoices are unchanged (no_gst false). SQL tests roll back; md5 baselines match at apply.
6. tsc clean. Unit tests for the mode mapping and totals, plus a SQL test per RPC.

## As built (2026-11-26)
- `lib/sale-calc.ts`: `GstMode`, `defaultGstMode`, `gstModeParts` (rate 0 for none), and `toGstMode` (drafts saved before this change stored a boolean).
- `GstModeToggle` has 3 options. `GstSummary` takes `mode`. All 7 screens pass `noGst`. The on-site offline job carries optional `noGst`.
- Invoice page: the GST row always shows. When gst = 0 it reads "GST not charged" and the total label is "Total".
- Rollback rehearsed: migration → rollback → all 8 function md5s and ACLs equal the live baseline, columns gone.
