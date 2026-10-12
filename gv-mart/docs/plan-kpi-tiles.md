# Plan: KPI tiles for the master's dashboard and Reports area (Item 7)

Status: **design approved with all 7 defaults (Q1-Q7).** Step 1 and 1b are built (code only, local, unpushed). Step 2 scope is
in section 10 and is **awaiting approval; nothing of Step 2 is built.** Approval conditions that apply to every later step:
(a) before any margin tile, count invoice lines with no cost snapshot in the real org (done: 0 lines in total, so 0 missing;
re-run before Step 3) and ship a "cost missing" flag with the margin tile regardless; (b) the Product / Spare / Service tiles
state that spares used on a service visit count as Service; (c) the headline revenue becomes net of GST with gross as a
sub-line, and the tile's help text says the basis changed.
Written against `origin/main` at `e53a1f7` (fetched 2026-10-12 session; the local `main` checkout is 24 commits ahead and
113 behind, so it was not used as the source).

Source of truth for "what exists": the migrations in `gv-mart/supabase/migrations/` and the code in `gv-mart/src/`. The live
database was **not** queried for this document (see section 7).

---

## 1. What already exists

### 1.1 Reports screens (`src/app/admin/reports/`)

| Screen | Reads from | Notes |
|---|---|---|
| Sales & Service (`SalesServiceReportTab`) | `report_sales_service` | revenue by class, visits, calls, per technician |
| P&L (`PnlReportTab`) | `report_pnl` | invoiced vs collected, expenses by category, item profit |
| Top Customers | `report_top_customers` | ranked by invoiced total |
| Performance | `report_performance`, `report_ops_resolution` | per technician |
| Feedback | `report_feedback` | ratings |
| Coverage | `report_coverage` | warranty / AMC / rental by month, installs |
| Sales Insights | `report_customer_totals`, `report_product_sales`, `get_lead_funnel` | |

### 1.2 SQL report functions already live (migrations `20261009100000/110000/120000`, test flag `20261016110000`)

All are `SECURITY DEFINER`, `STABLE`, org taken from `current_org_id()` through `_report_org()` (staff only), plain-date
in / half-open IST window out, `EXECUTE` for `authenticated` only.

| Function | Returns (key fields) | Tables / columns | Test exclusion today |
|---|---|---|---|
| `_report_invoice_base` | one row per invoice with revenue class | `invoices` (type, total, gst, amount_paid, customer_id, created_at), `service_tickets.invoice_id`, `service_visits` | `not is_test_customer(customer_id)` |
| `report_sales_service` | by class: count, qty, total, gst, net, collected; visits; calls; per-technician; avg service call | above + `invoice_items.qty`, `service_visits.service_charge/timer_start`, `call_logs.called_at` | invoices via base; visits via `_visit_is_test` |
| `report_pnl` | invoiced / collected (total, gst, net); expenses by category (master only); item profit (revenue, cost, gifts cost, missing_cost_count) | `invoices`, `invoice_items` (qty, price, discount, cost), `gift_logs.cost`, `expenses` (category, amount, date) | invoices + items + gifts via `_invoice_is_test`; **expenses carry no customer link, so they are org-scoped only** |
| `report_customer_totals` | total / new customers, buyers, new vs repeat, repeat rate, revenue per buyer | `customers`, `invoices` | `not is_test` + base |
| `report_product_sales` | per item: qty, revenue, cost, profit, margin, share | `invoice_items` (item_type product/spare), `products`, `spares` | `_invoice_is_test` |
| `report_top_customers` | ranked customers | via `_report_invoice_base` | via base |
| `report_coverage` | monthly warranty/AMC/rental visits + active + plan value; installs per technician / per product / per visit | `service_visits`, `service_tickets`, `warranties`, `amc_contracts`, `amc_plans`, `rental_contracts`, `rental_plans`, `installations_logged`, `invoice_items` | `is_test_customer` / `_visit_is_test` |
| `report_performance` | per technician: jobs, on-time %, revenue, rating, lead conversion, minutes, productivity, installs | `service_visits`, `ratings`, `leads`, `attendance`, `installations_logged` | `_visit_is_test`, `not l.is_test` |
| `report_ops_resolution` | % of completed tickets resolved within 24h | `service_tickets` (status, created_at, updated_at) | `is_test_customer` |
| `report_feedback` | star distribution, average, trend, low-rating list | `ratings`, `service_visits`, `notifications` | `_visit_is_test` |
| `report_expenses_salary_by_staff` | salary by staff (master only) | `expenses` (category='salary', staff_id) | exempt in manifest (no customer data) |
| `report_expenses_year_over_year` | per year totals + YTD comparable + by category (master only) | `expenses` | exempt in manifest |
| `get_lead_funnel` | totals by status, reached-stage funnel, by source | `leads`, `lead_stage_log` | `not l.is_test` |
| `followup_counts`, `list_followups`, `list_leads_without_followup`, `list_post_service_followups` | follow-up queue counts | `lead_followups`, `leads`, `service_tickets` | in manifest `must_exclude` |
| `technician_kpi_summary` | avg call value, referrals, reviews, installs per technician | `service_visits`, `invoices`, `customer_members` | `is_test_customer` |
| `referral_overview` / `v_referral_events` | referrals by technician (read model, 20261016140000) | `leads`, `service_tickets` | `not l.is_test` |

CI guard: `supabase/test-customer-guard.manifest.json` + `src/lib/testCustomerGuard.test.ts` fail the build if a function
named like a report/KPI/count is neither `must_exclude` (and references the flag) nor `exempt` (with a reason).

### 1.3 Dashboard tiles today (`src/app/admin/dashboard/`)

| Dashboard | Tile | How it is computed | Test data excluded? |
|---|---|---|---|
| Owner | Total Revenue (+ collected) | `report_pnl` (GST-inclusive invoiced) | yes |
| Owner | Today's Sales (+ collected) | `report_sales_service` for today (IST) | yes |
| Owner | Revenue mix, Top technicians | `report_sales_service` | yes |
| Owner | P&L trend chart | `report_pnl` per month | revenue yes; expenses org-scoped |
| Owner | **Open Tickets** | client-side count over `useTicketsList` | **no** |
| Owner | **Lead Conversion** | client-side count over `listLeads` (`select *` on `leads`, no `is_test` predicate) | **no** |
| Owner / Attention | **AMC due soon** | client-side over `useAmcContracts` | **no** |
| Owner / Attention | Low stock | client-side over spares inventory (stock, not customer data) | n/a |
| Ops | Completed today, Open tickets, On-duty techs, Attendance | client-side | open tickets: no |
| Sales | Open leads, Quotation→Sale, Lead pipeline, Source conversion | client-side | **no** |
| Huddle | Open tickets | `service_tickets` joined `customers!inner(is_test)` | yes |

Existing-defect finding (relevant to requirement 3): three Owner tiles (Open Tickets, Lead Conversion, AMC due soon) and the
Sales dashboard lead tiles are computed in the browser from unfiltered lists, so a flagged test customer's lead/ticket/AMC
**does** show up in them today. The Customers list (`customers.ts`) and Huddle already filter correctly.

---

## 2. Conventions every tile follows

1. **Window:** period tiles take `(p_from date, p_to date)` and use the half-open IST window
   `[p_from 00:00 IST, (p_to + 1) 00:00 IST)` via `_report_ist_start()`, exactly like the existing `report_*` functions.
   Tables keyed by a plain `date` (expenses, attendance) use `date >= p_from and date <= p_to`.
2. **Live tiles** (open tickets, outstanding, follow-ups, AMC book) are "as of now, IST" and ignore the period; they are
   shown dimmed with a "live" badge, matching the existing Today's Sales convention.
3. **Comparison:** each period tile may show a delta against the immediately preceding window of equal length
   (computed by the same function with shifted dates, never by the browser).
4. **Org scope:** from `current_org_id()` via `_report_org()`; no org parameter.
5. **Test exclusion:** see section 4.
6. **Money:** rupees, `numeric(12,2)`, rounded only at the edge; GST handling stated per tile.
7. **Visibility:** spend/profit tiles master-only (expenses RLS is master-only); other tiles staff.

---

## 3. Proposed tile set (master's dashboard)

"Existing" means the number is already produced by a live function; "new" means it needs the new function in section 6.
Headline row (shown first): tiles 1, 2, 5, 10, 12, 14.

### Money

**1. Revenue invoiced** (existing)
- Definition: sum of `invoices.total` for invoices created in the window, excluding test customers; sub-line shows GST and
  the net-of-GST figure (`total - gst`).
- Source: `_report_invoice_base` -> `invoices.total, gst, created_at, customer_id`.
- Date: invoice `created_at` in IST window.
- Meaning: "How much did we bill this period?"

**2. Revenue collected** (existing)
- Definition: sum of `invoices.amount_paid` over the same set of invoices (so it is "of what we billed in this window, how
  much has been paid so far", not cash received in the window).
- Source: `invoices.amount_paid`.
- Date: invoice `created_at` in IST window.
- Meaning: "Of this period's bills, how much money has actually come in?"

**3. Outstanding receivable** (new, live)
- Definition: sum of `invoices.total - invoices.amount_paid` where `payment_status in ('partial','due')`, all dates, non-test
  customers, as of now. Also shows count of such invoices and the oldest created date.
- Source: `invoices(total, amount_paid, payment_status, created_at, customer_id)`.
- Date: live (not period).
- Meaning: "Money customers still owe us."

**4. Spend** (existing, master only)
- Definition: sum of `expenses.amount` with `date` in the window, plus split by category.
- Source: `expenses(category, amount, date)`; categories: marketing, stationery, salary, petrol, purchase, other, rent,
  electricity, parking, ad_campaign, video_generation.
- Date: `expenses.date` (a plain IST date), inclusive both ends.
- Meaning: "What money went out this period?" Category mapping is open question Q1.

**5. Cash profit** (existing, master only)
- Definition: (collected net of GST) minus spend, i.e. `report_pnl.collected.net - sum(expenses)`.
- Source: as tiles 2 and 4.
- Date: window as above.
- Meaning: "Money in minus money out." Honest caveat on the tile: collected is cohort-based and purchases are counted when
  billed, not when sold (Q1).

**6. Item margin** (existing)
- Definition: `sum(qty*price - discount) - sum(qty*cost) - gifts_cost` over invoice lines that have a cost snapshot;
  shown with a `missing_cost_count` badge. Margin % = profit / revenue.
- Source: `invoice_items(qty, price, discount, cost)`, `gift_logs.cost`.
- Date: line `created_at` in IST window.
- Meaning: "On what we actually sold, how much was left after the cost of those goods?" Lines with no cost are excluded and
  counted, never treated as zero cost.

### Sales mix

**7. Revenue by stream** (class level existing; Product vs Spare split new, see Q2)
- Definition: invoiced total (GST-inclusive, as the report) by stream: Product, Spare (counter), Service, AMC, Rental.
- Source: `_report_invoice_base.class` (sales/service/amc/rental) plus `invoice_items.item_type` to split `sales`.
- Date: invoice `created_at` in IST window.
- Meaning: "Where does our revenue come from?" The five slices always add up to tile 1.

**8. Units sold and average invoice** (existing)
- Definition: units = `sum(invoice_items.qty)` where `item_type='product'`; average invoice value = class `sales` total /
  class `sales` invoice count.
- Source: `report_sales_service.by_class.sales`, `report_coverage.installation.units_sold`.
- Date: IST window.
- Meaning: "How many products did we sell, and how big is a typical sale?"

### Leads

**9. New leads** (existing)
- Definition: count of `leads` created in the window with `is_test = false`; by-source breakdown on drill-down.
- Source: `get_lead_funnel.total`, `by_source`.
- Date: `leads.created_at` in IST window.
- Meaning: "How many new enquiries came in?"

**10. Lead to Won rate** (existing, replaces the client-side tile)
- Definition: leads created in the window that are now `status='won'` divided by all leads created in the window (lost
  leads stay in the denominator). Shown with won / total.
- Source: `get_lead_funnel.by_status`.
- Date: cohort = `leads.created_at` in IST window.
- Meaning: "Of the enquiries that arrived this period, what share became a sale so far?"

**11. Follow-ups needing action** (existing, live)
- Definition: overdue + due-today open follow-ups, plus leads with no follow-up set.
- Source: `followup_counts`, `list_leads_without_followup` (count).
- Date: live, IST today.
- Meaning: "How many leads are waiting on us right now?"

### Service and retention

**12. Open tickets** (existing logic, new server-side source, live)
- Definition: `service_tickets` with `status in ('open','assigned','in_progress')`, customer not test. Sub-line: very
  urgent/urgent count (`priority`) and tickets past `sla_due_at`.
- Source: `service_tickets(status, priority, sla_due_at, customer_id)`.
- Date: live.
- Meaning: "How much service work is waiting?"

**13. Resolved within 24 hours** (existing)
- Definition: completed tickets created in the window where `updated_at - created_at <= 24h`, as a % of completed tickets.
- Source: `report_ops_resolution`.
- Date: ticket `created_at` in IST window.
- Meaning: "How often do we fix things within a day?"

**14. Customer rating** (existing)
- Definition: average `ratings.stars` for visits that started in the window; sub-line shows number of ratings and number
  below 4.5.
- Source: `report_feedback.average_rating`, `low_rating_entries`.
- Date: rating `created_at` in IST window (as the existing function).
- Meaning: "How happy are customers with our visits?"

**15. AMC book** (existing in parts, new as a tile, live)
- Definition: AMC contracts with `cancelled_at is null` and `start_date <= today <= expiry_date` (active), plus those in the
  configured renewal window (`amc_contracts.status = 'due_soon'`), plus AMC revenue for the period (class `amc`).
- Source: `amc_contracts(start_date, expiry_date, cancelled_at, customer_id)`, class `amc` from the base.
- Date: live for counts; IST window for revenue.
- Meaning: "How many customers are under AMC, and how many renewals are coming up?"

**16. Repeat buyers** (existing)
- Definition: of customers who bought in the window, the share who had bought before the window start.
- Source: `report_customer_totals.repeat_rate_percent`.
- Date: IST window.
- Meaning: "Are customers coming back?"

---

## 4. Test-data exclusion (requirement 3)

Facts found:
- Two flags exist: `customers.is_test` and `leads.is_test` (migration `20261016110000`). A lead is flagged when its customer is
  flagged **or** its mobile key equals a flagged customer's mobile; kept in sync by triggers.
- There is no `is_test` column on `invoices`, `service_tickets`, `service_visits`, `expenses`, `ratings`. Test-ness reaches
  them only through the customer, via helpers `is_test_customer`, `_invoice_is_test`, `_ticket_is_test`, `_visit_is_test`.
- A `__TEST_` organisation is identified only by `organizations.name LIKE '\_\_TEST\_%'` (used by
  `purge_test_organisation` and the SQL tests). **No report function tests the organisation name.** They are safe from
  `__TEST_` data only because every function is scoped to the caller's own `current_org_id()`.

Rules for the tile function:
1. Customer-linked rows: always the existing helpers (`is_test_customer`, `_invoice_is_test`, `_visit_is_test`) or
   `not leads.is_test`; invoices only through `_report_invoice_base`.
2. Rows with no customer link (`expenses`, `gift_logs` without invoice): org-scoped only, as today. A flagged customer's
   purchases are not in expenses, so nothing to exclude; stated explicitly in the function header.
3. Organisation: the function is org-scoped and takes no org parameter, so a `__TEST_` org's rows can never be summed into a
   real org's tiles. See Q3 for the one subtlety (a `__TEST_` org viewing its own tiles).
4. Browser-side tile math is not allowed for any tile above. The three unfiltered Owner tiles move to server functions.
5. The new function is added to `must_exclude` in the manifest so CI proves it references the flag.

---

## 5. Open questions and recommended defaults

| # | Question | Recommended default | Why |
|---|---|---|---|
| Q1 | **Expense mapping.** `expenses.category` mixes operating costs (rent, electricity, salary, marketing, ad_campaign, video_generation, petrol, parking, stationery, other) with stock purchases (`purchase`, written when a bill or PO is paid). Item margin (tile 6) already subtracts the cost of goods sold from `invoice_items.cost`. Subtracting purchases as well would charge stock cost twice. Which categories count as what? | **Cash profit (tile 5)**: all categories, cash basis, exactly as P&L does today. **Item margin (tile 6)**: cost of goods from `invoice_items.cost` only. **Operating spend** shown as a sub-line: every category except `purchase`; `salary` shown separately. Never subtract both `purchase` and item cost in one number. The tile footnote says which basis it is. | Matches the existing P&L screen so numbers agree; avoids double counting; no schema change. |
| Q2 | **Product vs Spare split.** Class `sales` today lumps product invoices and counter spare sales; class `service` is the whole total of a spare invoice raised from a service visit (including service charge). Spares appear in three places. How is "Spare" defined? | **Product** = invoice lines `item_type='product'` on class `sales` invoices. **Spare (counter)** = lines `item_type='spare'` on class `sales` invoices. **Service** = class `service` invoice totals, unchanged (spares used on a visit are part of service, not Spare). The three plus AMC and Rental reconcile to tile 1 at invoice level; line-level shares are shown as a percentage of class-sales revenue. | Keeps the existing revenue-class decision (one invoice, one class, counted once); a reconciliation test pins it. |
| Q3 | **`__TEST_` organisation.** A `__TEST_` org's own users, viewing their own tiles, are the only way the tiles can be tested. Hiding them there would make the tiles untestable. | Exclusion = org scoping (no cross-org sums, no org parameter), proven by a test that seeds a second `__TEST_` org with large numbers and asserts the first org's tiles do not move. No `name like __TEST_` predicate inside the tile function. If you want a literal predicate anyway, it would belong in a future cross-org/platform view, not here. | The literal rule would blank the test org's own tiles and leave nothing to verify against. |
| Q4 | **Headline revenue basis.** Owner dashboard headline is GST-inclusive today; profit tiles are net of GST. | Headline = **net of GST**, with the gross figure as the sub-line; the revenue-by-stream slices keep gross (as the report) with the basis labelled. | A profit figure next to a gross revenue figure invites a wrong mental subtraction. Reversible in the UI only. |
| Q5 | **"Collected".** There is no payment-event ledger; `invoices.amount_paid` is a running total. | Keep the cohort definition (tile 2) and label it "paid so far on this period's bills". Do not call it "cash received this month". | It is the only number the data can support truthfully. |
| Q6 | **Lead to Won denominator.** | All leads created in the window (lost included), as `get_lead_funnel` and the current tile. | Consistency with the Reports screen. |
| Q7 | **Who sees spend/profit tiles.** | Master only (matches expenses RLS); operation/sales admins see tiles 1-3 and 7-16 without the money-out tiles. | Existing RLS; no new exposure. |

---

## 6. Technical shape (for approval, not built)

- One new additive function `report_kpi_tiles(p_from date, p_to date)` returning one jsonb document, built from
  `_report_invoice_base` and the existing per-tile logic, so every tile reads the same invoice set and the same window.
  It composes rather than duplicates: where a live function already returns a value, the new function either calls the same
  helper or the UI keeps calling the existing function. New logic is only: tile 3 (outstanding), tile 7 split, tile 12
  server-side, tile 15 summary.
- `STABLE SECURITY DEFINER`, `search_path = public`, `_report_org()`, `EXECUTE` to `authenticated` only, `anon` revoked.
- Added to the CI manifest `must_exclude`.
- No new tables, no changes to existing functions, no data writes.
- UI: a tile grid component on the Owner dashboard fed by that one query; i18n keys in `en` and `ta`; Sales/Ops dashboards
  re-point their lead/ticket tiles to the same server numbers.

---

## 7. What could not be found / not verified

- **Live database state was not queried.** I did not confirm that every migration in the repo is applied, the real row
  counts, how many invoice lines lack a cost snapshot, or whether any real-org rows carry `is_test = true` besides the one
  documented test customer.
- **No payment-event ledger** (no payment date per instalment). Tile 2 can only be cohort-based (Q5).
- **No void / cancelled state on invoices** was found; every invoice is counted.
- **No targets or budget table**, so no "vs target" tiles are possible.
- **No first-response-time field** on tickets or leads, so no response-time tile.
- **`call_logs`** (calls count in `report_sales_service`) is not test-filtered; I did not confirm whether it links to
  customers. Not used by any proposed tile.
- **No `__TEST_` predicate exists in any report function** (see section 4); the design relies on org scoping.
- The AMC "due soon" window length is a configured value read inside the AMC status function (`20260702110100`); I did not
  confirm the live setting, so tile 15 uses the contract's own `due_soon` status rather than a hard-coded 30 days.

---

## 8. How the tiles would be tested (throwaway data only)

Follows the existing pattern in `supabase/tests/*.test.sql` (for example `reports_sql_aggregation_1.test.sql`,
`amc_and_test_flag.test.sql`): everything inside one transaction that ends in `RAISE`, a throwaway `__TEST_` organisation
created inside it, users via the same `mkuser` helper, real-data fingerprints before and after to prove nothing real moved.
Nothing is committed to the database and no WhatsApp or outbound call is possible (the outbox is not touched).

Seed (hand-computable numbers, fixed IST timestamps):
- 3 ordinary customers, 1 flagged `is_test` customer with a lead sharing its mobile key.
- Invoices: product (2 lines, one with no cost), counter spare, spare raised from a ticket with a visit (service), AMC,
  rental; one paid, one partial, one due; two placed exactly at the IST midnight boundary (`18:29:59` and `18:30:00` UTC).
- Expenses: purchase, salary (with staff_id), rent, electricity, ad_campaign; one dated on the window's first and last day.
- Leads: new/contacted/quoted/won/lost across two sources; tickets: open, assigned, completed < 24h, completed > 24h,
  one past SLA; ratings 5, 4, 3; AMC contracts active, expiring in 20 days, cancelled.
- A second `__TEST_` organisation with large numbers.

Assertions:
1. Each tile equals the hand-computed value.
2. **Test-exclusion:** run the tile function, add invoices/leads/tickets/AMC/ratings for the flagged customer, run again;
   output byte-identical. Repeat for the flagged lead matched by mobile only.
3. **Org isolation:** the second `__TEST_` org's numbers never appear in the first org's tiles.
4. **IST boundary:** the two boundary invoices fall on different sides of the day; a window ending that day includes only
   the first.
5. **Parity:** tiles 1, 2, 4, 5, 6, 10, 13, 14, 16 equal `report_pnl`, `report_sales_service`, `get_lead_funnel`,
   `report_ops_resolution`, `report_feedback`, `report_customer_totals` for the same window (so the dashboard can never
   disagree with the Reports screen).
6. **Reconciliation:** Product + Spare (counter) + Service + AMC + Rental revenue = tile 1; Q1 mapping: item margin never
   includes `purchase`.
7. **Permissions:** `anon` and a customer role cannot execute; a non-master receives no spend/profit values; an inactive
   staff user is refused (existing `_report_org` behaviour).
8. **Empty window** returns zeros / nulls, no division errors.
9. Real-data fingerprints (invoices, expenses, leads, tickets outside `__TEST_` orgs) unchanged.

Front end: vitest mapper tests (as `reportMappers.test.ts`), plus the existing `testCustomerGuard.test.ts` covers the
manifest entry. Browser check on a `__TEST_` org login only.

---

## 9. Build order (each step stops for review)

1. **Step 1 - no database change.** Move the three unfiltered Owner tiles and the Sales dashboard lead tiles to filtered
   sources (`customers!inner(is_test)` as `huddle.ts` already does, or `get_lead_funnel` / `followup_counts`). Immediate
   fix of the existing test-data leak. Vitest only.
2. **Step 2 - one additive migration** `report_kpi_tiles` + manifest entry + SQL test file from section 8. Applied to a
   throwaway transaction first (rollback), then applied for real only on separate approval.
3. **Step 3 - UI tile grid** on the Owner dashboard (headline row, then groups), period filter reuse, live-tile dimming,
   en + ta strings.
4. **Step 4 - Reports area** gets the same tile strip at the top of each report tab where relevant (money on P&L, mix on
   Sales & Service, leads on Sales Insights).
5. **Step 5 - verification:** parity run against the real organisation, read-only, comparing tiles with the existing
   reports; browser check; production check.

Out of scope here: any write to live data, notifications, WhatsApp sends, and changes to existing report functions.


---

## 10. Step 2 - exact scope (nothing built; for approval)

Steps 1 and 1b (browser-side leak fixes) are done and independent of this. Step 2 is the database side only: one additive
read function, its tests, and the CI manifest entry. No UI. No change to any existing function.

### 10.1 Tiles Step 2 covers

| Tile | Step 2 source |
|---|---|
| 1 Revenue invoiced (net + gross) | `_report_invoice_base` sums |
| 2 Revenue collected | `_report_invoice_base.amount_paid` |
| 3 Outstanding receivable (live) | **new**: `invoices` `total - amount_paid` where `payment_status in ('partial','due')`, non-test |
| 4 Spend (master only) | `expenses` by `date`, by category |
| 5 Cash profit (master only) | collected net - spend (Q1: all categories, cash basis) |
| 6 Item margin + `cost_missing` flag | `invoice_items` with cost snapshot; `missing_cost_count`; `cost_missing = missing_cost_count > 0` |
| 7 Revenue by stream | **new split**: Product / Spare (counter) / Service / AMC / Rental (Q2); carries the note "spares used on a service visit count as Service" |
| 8 Units sold, average invoice | product `qty`; class `sales` total / count |
| 9 New leads, 10 Lead to Won | composed from `get_lead_funnel` |
| 12 Open tickets (live, + urgent, + past SLA) | **new**: `service_tickets` joined to customer, non-test |
| 13 Resolved within 24h | composed from `report_ops_resolution` |
| 14 Customer rating | composed from `report_feedback` (average, count, below 4.5) |
| 15 AMC book (live) | **new**: `amc_contracts` active / `due_soon` / expiring, non-test, not cancelled |
| 16 Repeat buyers | composed from `report_customer_totals` |

Not in Step 2: tile 11 (follow-ups). `followup_counts` is scoped by who is asking (it reads `auth.uid()`), so it stays its own
call from the UI in Step 3.

### 10.2 Migrations

Exactly one, version chosen at apply time from the then-current `origin/main` (latest today is `20261016160000`; other
sessions have been consuming the following numbers, so re-check `schema_migrations` and origin/main first). Working name:
`20261016170000_report_kpi_tiles.sql`.

| Part | What it changes | Rollback |
|---|---|---|
| `create function public.report_kpi_tiles(p_from date, p_to date) returns jsonb` | New function, `STABLE SECURITY DEFINER`, `search_path = public`, org from `_report_org()`, IST half-open window from `_report_ist_start`; `revoke all ... from public, anon`; `grant execute ... to authenticated` | `drop function public.report_kpi_tiles(date, date);` |
| `create index if not exists invoices_org_outstanding_idx on public.invoices (org_id) where payment_status <> 'paid'` | Partial index so tile 3 stays cheap as invoices grow. Additive. | `drop index if exists public.invoices_org_outstanding_idx;` |
| `notify pgrst, 'reload schema'` | Makes the RPC visible | none needed |

No table, column, trigger, policy or data change. Because it is purely additive, rollback is the two `drop` statements above and
nothing else depends on them. Before applying live (separate approval): backup of the live function bodies as for earlier
batches, ACL snapshot, `schema_migrations` check, real-org lead hashes before and after, hand-registered history row.

### 10.3 Existing SQL functions touched

**None are replaced or altered.** The new function only calls:
`_report_org`, `_report_ist_start`, `_report_invoice_base`, `is_test_customer`, `_invoice_is_test`, `_visit_is_test`,
`is_master`, and, for composed tiles, `report_ops_resolution`, `report_feedback`, `report_customer_totals`, `get_lead_funnel`
(called with `p_to` = window end minus one microsecond, because `get_lead_funnel` uses `<= p_to`).

Non-SQL files touched: `supabase/test-customer-guard.manifest.json` (add `report_kpi_tiles` to `must_exclude`), a TypeScript
mapper + type for the jsonb (`src/services/reportMappers.ts`, with a vitest file), and `src/types/database.ts` (hand-patched,
as CLI type generation needs Docker). No React component changes in Step 2.

### 10.4 Test plan

SQL test `supabase/tests/report_kpi_tiles.test.sql`, same harness as `reports_sql_aggregation_*.test.sql`: one transaction
that ends in `RAISE`, so it is rolled back and needs no purge. Run on the live database through the Management API with the
migration text concatenated in front (so the function does not have to be applied first). Real-data fingerprints before and
after.

Seed (two throwaway organisations, both named `__TEST_...`):
- **Org A** (the one the tiles are read from): 3 normal customers; 1 flagged `is_test` customer plus a lead that shares its
  mobile; invoices of every class (product with one cost-less line, counter spare, spare raised from a ticket with a visit,
  AMC, rental) paid / partial / due; two invoices exactly at the IST midnight boundary; expenses in purchase, salary, rent,
  electricity, ad_campaign; leads across statuses and sources; tickets open / assigned / completed < 24h / completed > 24h /
  past SLA; ratings 5 / 4 / 3; AMC active / due_soon / cancelled.
- **Org B**: its own customers, invoices, expenses, leads, tickets, ratings, AMC with deliberately large values.

Assertions:
1. Every tile equals its hand-computed value.
2. **Org B must not move Org A's tiles:** run as an Org A master, record the output; insert more rows into Org B; run again;
   byte-identical. Also run as an Org B master and confirm it sees only Org B.
3. **Flag test:** add invoices, leads, tickets, AMC, ratings for the flagged customer (and a lead matched by mobile only);
   output byte-identical.
4. IST boundary: the two boundary invoices land on opposite sides; an empty window returns zeros / nulls with no divide errors.
5. **Parity:** tiles 1, 2, 4, 5, 6, 9, 10, 13, 14, 16 equal `report_pnl`, `report_sales_service`, `get_lead_funnel`,
   `report_ops_resolution`, `report_feedback`, `report_customer_totals` for the same window.
6. **Reconciliation:** Product + Spare + Service + AMC + Rental revenue = tile 1 (invoice level); item margin never includes
   `purchase`; `cost_missing` is true exactly when a cost-less line is in the window.
7. Permissions: `anon` and a customer role cannot execute; a non-master gets null spend / cash profit; an inactive staff
   user is refused.
8. CI: `testCustomerGuard.test.ts` passes with the new manifest entry (fails if the function stopped referencing the flag).
9. After a separately approved live apply: read-only parity run against the real organisation, which currently has 0
   invoices, so it mainly proves zeros and the flagged customer's exclusion.

### 10.5 Order

1. Branch from `origin/main` (fetch first); write the migration file and the SQL test file. Nothing applied.
2. Run the SQL test as a rolled-back transaction on live; fix until green. Real-org fingerprints unchanged.
3. Manifest entry, TypeScript mapper + types, vitest; `tsc -b` and full vitest clean.
4. **Stop for review** with the diff and test output.
5. On approval only: backups, ACL snapshot, apply, register history row, hash and ACL re-check, read-only parity.
6. Stop. Step 3 (UI tile grid, en + ta strings, help text for conditions (b) and (c)) is a separate approval.

Not part of Step 2: any UI, any WhatsApp or notification path, any change to the older `__TEST_ GV Mart` organisation (its
purge is approved separately), and any push or deploy.
