# Sales & Invoices KPI tiles - design (item 7)

Status: DESIGN ONLY. No code, no database change. Written 2026-10-12 against `origin/main` `68beac4`.
Page: `/admin/sales` (`src/app/admin/sales/SalesListPage.tsx`, route "Sales & Invoices").

## 1. What the page does today (from the code)

### Does it cover AMC?
Yes. A cart sale is split by `create_sale` into up to three invoices (spare, product, AMC), and every
one of them is listed. AMC invoices have type `amc`, show an "AMC" badge, have their own filter chip, and
are included in "Today's Sales", "This month" and "Avg Ticket Value". What is **not** there: any tile
that shows AMC on its own. There is no "Rent" filter chip either, although rent invoices are listed and
counted in the totals.

### What the four tiles show
| Tile | Number | Window | Which invoices |
|---|---|---|---|
| Today's Sales | sum of `total`, plus "Collected" (sum of `amount_paid`), plus % vs yesterday | today | **all** invoices, all types, paid or not |
| Product Sales | sum of `total` of `type = product` + "x% of revenue" | this month | product invoices only; the % divides by **all** invoices of the month |
| Avg Ticket Value | sum of `total` / invoice count (+ % vs last month) | this month | **all** invoices, all types |
| Quotation -> Sale | converted / (converted + lost) | all time | quotations |

### What the filters do
The "All types / Product / Spare / AMC" chips and the search box filter **the table only**. The tiles
ignore them: they always show the whole organisation, for today and for this month. There is no date
filter on this page.

### Paid versus all invoices
Every headline number uses **all** invoices at their full `total` (GST-inclusive), whatever their
`payment_status` - a partly paid or unpaid invoice counts in full. Only the small "Collected" line under
Today's Sales uses `amount_paid`. There is no "due" figure on any tile (the table shows a "balance due"
per row). Same convention as the Reports tab: headline = invoiced, collected shown beside it.

### Things in the current implementation worth knowing
1. **Spare is not "spare sale".** A service invoice raised by a technician is stored as `type = spare`, so
   the Spare chip and any spare total mix counter spare sales with service invoices (the Reports tab
   already separates them; this page does not).
2. **1,000-row cap.** `listInvoices` fetches every invoice of the organisation with no limit. PostgREST
   returns at most 1,000 rows, newest first, so month figures stay right until a single month passes
   1,000 invoices, but the table silently stops at the newest 1,000. The item-name lookup also sends
   every id in one `in (...)` URL, which will fail (400) once a page has a few hundred distinct items.
3. **Device clock, not IST.** "Today" / "this month" use the browser's local midnight. On a device outside
   IST the day boundary is wrong by hours (the Reports and dashboards already use IST).
4. **Invoice count, not sale count.** One cart with a product and an AMC is two invoices, so "average
   ticket" is per invoice, not per customer visit.
5. The "Product Sales" tile's "% of revenue" has all types in the denominator, including service
   invoices and rent.

## 2. Proposed tiles

Keep the existing layout (four cards, `lg:grid-cols-4`) and replace the middle two plus add one:

```
+------------------+------------------+------------------+------------------+
| Product sales    | Spare sales      | AMC              | Quotation->Sale  |
| TODAY            | TODAY            | TODAY            | (unchanged)      |
| Rs 17,110        | Rs 1,180         | Rs 2,360         | 0%               |
| 2 invoices       | 1 invoice        | 1 invoice        | 0 of 0 decided   |
| Avg Rs 8,555     | Avg Rs 1,180     | Avg Rs 2,360     |                  |
| Month: Rs ...    | Month: Rs ...    | Month: Rs ...    |                  |
+------------------+------------------+------------------+------------------+
```

and Today's Sales (the orange tile, all types) stays as the first card, so the row is five cards on
wide screens (`xl:grid-cols-5`) or the Quotation tile moves below on narrow screens. Each of the three
new cards has:

* headline = **invoiced total for today** (GST-inclusive, all invoices of that kind, paid or not - same
  convention as today);
* "n invoices - Avg Rs X" in the same box (the average ticket size you asked for);
* a muted second line with the **month** total and count, so "today" and "total" are both visible;
* a small "Collected Rs X" under the headline (reuses `reports.collectedLabel`), so unpaid balance is
  visible without a new concept.

Average ticket = total / number of invoices of that kind (not per unit). With no invoices it shows
"-" (never Rs 0).

### Definitions (proposed defaults)
| Tile | Included invoices |
|---|---|
| Product | `type = product` |
| Spare | `type = spare` that is **not** a service invoice (counter spare sales). Service invoices get their own muted line "Service invoices: n - Rs X" on the Spare card, so nothing disappears |
| AMC | `type = amc` |

Rent has no tile (it is in Today's Sales and the table only). It could be added as a fourth small card
if wanted.

## 3. SQL changes

**One small additive change, no new function.** `report_sales_service(p_from, p_to)` already returns
`by_class` (sales / service / amc / rental) and `by_invoice_type` for any plain-date window, with the
invoice set shared with P&L. What it cannot do is split `sales` into product vs counter spare. Add one
key to its jsonb, `by_kind`:

```
by_kind: { product, spare_counter, service, amc, rental }   // each { count, total, gst, collected }
```

* Created with `create or replace function` in a new migration (additive: old frontend ignores the
  new key; same signature, same ACL assertions as the 3 report migrations).
* Derived from the same `_report_invoice_base` rows: product = `invoice_type = 'product'`,
  spare_counter = `invoice_type = 'spare' and class = 'sales'`, service = `class = 'service'`.
* `avg ticket` is computed in the mapper (`total / count`), as `avgValue` already is.

Frontend: reuse `useSalesServiceReport(orgId, range)` twice (today, this month). This also moves the
page's client-side totals off the 1,000-row path and onto IST. No new hook, no new query key shape.

**Not part of this change (separate, flag only):** the invoice *table* is still unbounded
(`listInvoices`). It needs a server-side limit / paging plus a chunked item-name lookup. Recommended as
its own small item; it does not block the tiles.

## 4. What each tile shows

### Real organisation today
0 invoices, 0 tickets, 0 AMC contracts, 3 customers, 0 quotations. Every tile shows Rs 0, "0 invoices",
"Avg -", month line "Rs 0 - 0 invoices"; Today's Sales shows "No sales yet today"; Quotation -> Sale
0%. Same as the current page, minus the average ("-" instead of 0).

### Small hand dataset (all in IST; "today" = Mon 12 Oct 2026, month = October)
| Invoice | Type / kind | Total | GST | Paid | When |
|---|---|---|---|---|---|
| I1 | product | 11,210 | 1,710 | 11,210 | today 12:00 |
| I2 | product | 5,900 | 900 | 2,000 | today 15:00 |
| I3 | spare, counter sale | 1,180 | 180 | 1,180 | today 16:00 |
| I4 | spare, service invoice (ticket + visit) | 1,062 | 162 | 1,062 | today 17:00 |
| I5 | amc | 2,360 | 360 | 2,360 | today 11:00 |
| I6 | rent | 590 | 90 | 590 | today 10:00 |
| I7 | product | 118 | 18 | 118 | 1 Oct 00:30 IST |
| I8 | amc | 2,360 | 360 | 2,360 | 6 Oct |
| I9 | spare, counter | 1,180 | 180 | 1,180 | 7 Oct |
| I10 | product | 354 | 54 | 354 | 30 Sep 23:50 IST (September, not October) |

| Tile | Today | This month | Notes |
|---|---|---|---|
| Today's Sales (all, unchanged) | 22,302 (collected 18,402) | n/a | I1-I6 |
| Product | 17,110, 2 invoices, avg 8,555.00, collected 13,210 | 17,228, 3 invoices, avg 5,742.67 | I2 is partly paid: counted in full, 3,900 unpaid shows via Collected |
| Spare (counter) | 1,180, 1 invoice, avg 1,180.00 | 2,360, 2 invoices, avg 1,180.00 | I4 not here |
| Spare card, service line | 1,062, 1 invoice | 1,062, 1 invoice | the service invoice, visible but separate |
| AMC | 2,360, 1 invoice, avg 2,360.00 | 4,720, 2 invoices, avg 2,360.00 | |
| Today with no AMC sold | Rs 0, "0 invoices", Avg "-" | month still shown | no division by zero |

Edge cases to expect: a zero-total warranty service invoice counts as an invoice in the service line
and pulls its average down (consistent with the Reports tab); I10 stays out of October because the
window is IST; a cart with product + AMC shows as one invoice in Product and one in AMC.

## 5. Decisions needed from the owner
1. **"Total" for Spare and AMC:** proposed = month total next to the today headline (all three tiles
   have the same shape). Alternative: a Today / This month / Year selector driving all tiles.
2. **Spare tile and service invoices:** proposed = counter spare sales only, service invoices on a
   muted line. Alternative: one Spare figure including service invoices.
3. Whether rent gets its own card.

## 6. Test plan (when built)
SQL test for `by_kind` using the dataset above (rolled-back, `__TEST_` org); mapper unit tests for
`avgTicket` including the zero-invoice case; parity: `by_kind` sums to `by_class` and to the invoice
total; a production check with a throwaway master and the same dataset.
