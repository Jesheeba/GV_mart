# GV Mart — Claude Design Workflow (Complete & Enhanced Edition)

A page-by-page design brief where **every screen lists (a) everything that should appear on it and (b) enhancement features that improve the original requirements.** Built to be handed to **Claude Design**.

> Read order: Section 0 (how to use) → Section 1 (overview) → Section 2 (design system) → Section 3 (global enhancements that apply everywhere) → Sections 4–6 (the three apps, screen by screen) → Section 7 (brand-new pages worth adding) → Section 8 (shared components) → Section 9 (phased order).

Legend used in every screen block:
- **APPEARS** = the full inventory of what must be visible/usable on that page.
- **ENHANCE** = upgrades that go beyond the original notes to make the feature better.

---

## 0. How to use this document with Claude Design

This system is **3 separate apps (surfaces):** Admin Web (desktop), Technician App (mobile), Customer App (mobile).

- **Per screen (recommended):** paste Section 2 (design system) once, then paste a single screen block (e.g. `ADM-05`). Each block is self-contained.
- **Per surface:** paste Section 2 + Section 3 + the navigation map + all screens for one surface.
- Every screen has an **ID** so you can iterate ("redo `TECH-07` with bigger buttons").
- Treat **ENHANCE** items as optional toggles — if you want a faithful build of the notes, skip them; if you want a better product, include them.

---

## 1. System overview

GV Mart sells and services home appliances (RO water purifiers, ACs, inverters, batteries). Revenue = product sales + spares + paid service + AMC contracts. Technicians travel to homes, so attendance, routing, and live tracking matter.

| Surface | Device | Users | Job |
|---|---|---|---|
| Admin Web | Desktop | Owner/Master, Operation Admin, Sales Admin | Run everything |
| Technician App | Phone | Technicians | Attendance, jobs, on-site service, invoicing |
| Customer App | Phone | Customers | Book service, enquiries, AMC/warranty status |

**Design priorities:** Admin = data-dense & fast. Technician = big targets, outdoor-readable, low-typing, works offline. Customer = simple & guided.

---

## 2. Design system (paste first, every time)

> **Visual direction: "Finexy" style** (from the uploaded reference). Warm, premium, friendly fintech look — a cream canvas, near-black as the primary action color, a coral-orange accent, big bold headings, large soft-rounded white cards, one filled-coral "highlight" card per section, pill-shaped nav and buttons, and clean tables with colored-dot status. Tell Claude Design: *"Match this reference aesthetic exactly."*

**Personality:** confident, warm, premium, uncluttered. Lots of whitespace; bold numbers; soft rounded everything.

### 2.1 Color tokens
| Token | Use | Hex |
|---|---|---|
| `ink` (primary) | primary buttons, active pill nav, chart bars, card art, headings | `#1A1A1A` (near-black) |
| `accent` | brand accent, highlight card fill, links, progress fill, key chart series | `#F5612C` (coral-orange) |
| `accent-soft` | accent tint backgrounds, hover | `#FDE7DD` |
| `bg` | app canvas | `#F4F1EC` (warm cream) |
| `surface` | cards/panels | `#FFFFFF` |
| `surface-alt` | sub-cards, table header, inputs | `#F7F5F1` |
| `border` | hairline dividers, card borders | `#ECE8E1` |
| `text` | primary text | `#1A1A1A` |
| `text-muted` | labels/secondary | `#8A8A82` (warm gray) |
| `success` | completed / paid / +% up / in-stock | `#2FAE5F` |
| `warning` | pending / in-progress / nearing limit | `#E8932B` |
| `danger` | late / overdue / −% down / out-of-stock | `#E5484D` |
| `info` | AMC / warranty | `#2E6BE6` |

**Gradient (optional):** subtle warm coral wash `#F5612C → #FF7A45` only on the single highlight card.

### 2.2 Status semantics (reused everywhere)
Shown as a **small colored dot + label** (not heavy pills): green = completed/paid/on-time/in-stock · orange = pending/in-progress/nearing-limit · red = late/overdue/out-of-stock · blue = AMC/warranty (free). Percentage deltas: green ▲ up, red ▼ down.

### 2.3 Typography
- Font: **Inter** or **Plus Jakarta Sans** (clean geometric sans).
- Greeting/page title: 28–32, bold. Section title: 18/24, semibold. Body: 14/20. Caption/label: 12/16, muted.
- **Numbers are the hero:** KPI figures large and bold (e.g. 28–34px), tabular numerals in tables/reports.

### 2.4 Shape, spacing, elevation
- 8px spacing grid; generous padding inside cards (20–24px).
- Radius: **cards 20px**, sub-cards 16px, inputs/buttons (pill) `rounded-full`, status dots small.
- Elevation: very soft, low-spread shadow on white cards over the cream canvas; hairline `border` where shadow isn't enough.

### 2.5 Component styling (match the reference)
- **Left sidebar:** thin, **icon-only**, floating with rounded corners; active item is a **dark (`ink`) rounded square**; muted icons otherwise.
- **Top bar:** logo as a rounded-square `accent` mark (left); **centered segmented pill nav** where the active tab is a solid `ink` pill with white text; right side = circular icon buttons (search, bell, info) + a user chip (avatar + name + caret).
- **Header block:** large bold greeting ("Good morning, …") + muted one-line subtitle.
- **KPI cards:** white card, small label + outline icon top, big bold number, a `% change` chip (green ▲ / red ▼) with "this month". **Exactly one highlight KPI per row uses the filled `accent` background with white text** (use it for the most important metric, e.g. Total Revenue / Today's Earnings).
- **Buttons:** primary = solid **`ink` pill**; secondary = **outline pill**; accent action/link = `accent`. Icons inline, pill shape.
- **Charts:** bars/series in **`accent` + `ink`**, minimal axes, simple top-right legend (e.g. Profit = accent, Loss = ink). Used for Revenue/P&L.
- **Progress bars:** `accent` fill on `surface-alt` track, `rounded-full`, with "spent / limit" labels.
- **Tables:** light `surface-alt` header row; optional leading **checkbox** column; row content with small brand/item icon; **status as colored dot + label**; trailing `…` action; top-right **search field + Filter/Sort pills**. Comfortable row height, hairline dividers, hover tint.
- **"Card" visuals → AMC plan tiers:** apply the reference's credit-card treatment (one `ink`, one `accent`) to **Gold/Silver/Platinum AMC plan cards** and to the highlight revenue card.

### 2.6 Layout
- **Admin Web:** floating icon sidebar + top bar (segmented pill nav) + content area of rounded cards on the cream canvas.
- **Mobile (Technician/Customer):** same palette and card/pill language; bottom tab bar; big tap targets; primary actions as `ink` pills, key CTAs in `accent`; sticky bottom action button on flow screens. Offer a dark mode for the Technician App (swap canvas to near-black, keep `accent`).

### 2.7 Reference-pattern → GV Mart mapping
| Finexy element | Use it for |
|---|---|
| Filled coral highlight KPI ("Total Earnings") | Dashboard **Total Revenue** (`ADM-01`); technician **today's earnings** (`TECH-10`) |
| Profit & Loss bar chart | **P&L** (`ADM-28`) and revenue trend (`ADM-01`) |
| Recent Activities table | Every list: tickets, customers, invoices, leads, inventory |
| Wallets sub-cards w/ status | Customer **products / AMC status** cards (`ADM-03`, `CUST-06`) |
| My Cards (ink + coral cards) | **AMC plan tiers** Gold/Silver/Platinum (`ADM-13`, `CUST-03`) |
| Segmented black pill nav | In-page tab/segment toggles (AMC/Warranty tabs, table/kanban switch) |
| Monthly Spending Limit progress | Stock vs reorder level, target vs actual, SLA usage |

---

## 3. Global enhancements (apply across all surfaces)

These improve the whole product; mention them to Claude Design as system-wide behaviors.

1. **Bilingual UI (English + Tamil)** with a one-tap switch — matches the Tamil voice-note requirement; field technicians and many customers prefer Tamil.
2. **Role-based access control + audit log** — every create/edit/delete is recorded with who/when (protects the "data safety / secured" requirement).
3. **WhatsApp + push notifications at every milestone** (booked, technician assigned, on-the-way with live link, completed, invoice, payment, feedback) — leverages the inbuilt WhatsApp requirement.
4. **OTP-verified service completion** — customer shares a one-time code (or taps a WhatsApp link) to confirm the job was actually done, before the invoice closes. Stops fake closures.
5. **UPI QR / payment link for "Transfer"** — instead of just storing a transaction ID, generate a UPI QR or payment link so money is captured and auto-reconciled.
6. **Offline-first Technician App** — attendance, job data, photos, and invoices queue locally and sync when signal returns (field areas have weak networks).
7. **Geotag + timestamp watermark** on before/after photos — tamper-proof proof of visit.
8. **Global command palette / quick search** on Admin Web (jump to any customer, ticket, product).
9. **Smart duplicate detection & merge** for customers (same mobile/address).
10. **Escalation matrix + SLA timers** — overdue tickets auto-escalate to Operation Admin; visible countdowns.
11. **Digital warranty/AMC card** (QR) in the Customer App — scannable proof of coverage.
12. **Loyalty/referral wallet** built on the existing "reference points" idea — points convert to discounts/credit.
13. **Dark mode for the Technician App** — outdoor readability and battery saving.
14. **Empty/loading/error states standardized** for every list and form.

---

## 4. ADMIN WEB — screens

> Shell on every page: left **Sidebar** (Dashboard · Customers · Sales · Service · AMC & Warranty · Technicians · Inventory · Suppliers & Purchase · Automation · HR & Payroll · Reports · Masters/Settings · My Workspace) + **Top bar** (global search, notifications bell, role/user menu, today's date) + **Content area**.

---

### ADM-00 · Login
**APPEARS:** logo; email/phone field; password field with show/hide; "remember me"; login button; forgot-password link; role-aware redirect; error banner; loading state on submit.
**ENHANCE:** OTP / 2-factor login; "login with Google"; device-remember; failed-attempt lockout; language switch on this screen.

---

### ADM-01 · Dashboard (Home)
**APPEARS:** KPI stat cards (Total Revenue with day/month toggle, Open Tickets, Today's Sales, Active Technicians, Lead→Sale conversion %, AMCs due this week); revenue trend line chart; Sales vs Service donut; top-technician scoreboard mini-leaderboard; live-tracking mini-map (green/red dots); alerts list (low stock, overdue tickets, AMC renewals); date-range selector; quick-action buttons (New Sale, New Complaint).
**ENHANCE:** customizable/draggable widget layout per role; "needs attention" smart feed (anomalies: revenue dip, technician idle, stock-out risk); target vs actual progress bars (monthly revenue goal); export dashboard as PDF; compare-to-last-period deltas on every KPI; forecast line (projected month-end revenue).

---

### ADM-02 · Customers — List
**APPEARS:** search-with-autocomplete (mobile/name); filters (address type, area/PIN, has-AMC, has-warranty, last-service date); data table (Name, Mobile, Area, Profession, #Products, AMC badge, Last service); row click → detail; Add Customer button; bulk export; pagination; empty state.
**ENHANCE:** saved filter views ("AMC due in 30 days"); map view of all customers (density by area for targeting); tags/segments (VIP, repeat, dormant); bulk WhatsApp campaign from a filtered set; duplicate-flag column; import customers from CSV; "dormant customer" auto-segment for win-back.

---

### ADM-03 · Customer — Detail / Profile
**APPEARS:** profile header (primary contact, profession, full address, address-type chips, geocoded district/state, map thumbnail); family-members panel (up to 5, set-primary, add/remove); tabs — Products owned (with warranty/AMC status), Service history timeline (type/technician/date/cost), Sales/Invoices, Enquiries/Leads; action buttons (New Sale, New Ticket, Sell AMC, Edit, Move-member-out→new customer); contact buttons (call, WhatsApp).
**ENHANCE:** customer lifetime value + revenue summary card; churn/at-risk indicator; "next best action" suggestion (e.g. AMC due, upsell); complete activity timeline (calls, messages, visits in one stream); attach documents (warranty cards, ID); private internal notes; preferred-language and preferred-slot fields.

---

### ADM-04 · Customer — Add / Edit (Stepper)
**APPEARS:** Step 1 People — Name+Mobile pairs, "+" to add member (max 5), Profession; Step 2 Address — Door/Flat/Street-Cross/Area/PIN/Landmark with autocomplete, address-type selector (Residential/Commercial · Own/Rental), auto District/State (editable/skippable), map confirm pin; inline validation; duplicate-mobile warning; Back/Next/Save.
**ENHANCE:** live duplicate detection while typing mobile; PIN-code auto-fills area/district; "use current location" to drop the map pin; WhatsApp opt-in checkbox; profile-completeness meter; capture source-of-acquisition here too.

---

### ADM-05 · Sales — New Sale (Stepper)
**APPEARS:** steps — Customer (search/add), Type (Spares/Product/AMC cards), Items (Product→Brand→Model or spares picker, qty, master price), AMC add-on (RO only; Gold/Silver/Platinum), Discount (with approval limits), Gift (auto-suggested past threshold, logged), Payment (Cash/Transfer; Transfer → mandatory Transaction ID + GPay/Bank description); right-rail running summary (line items, subtotal, discount, GST, total, gift flag); two-bill notice when product+spares together; Generate Invoice(s).
**ENHANCE:** UPI QR / payment link generation on Transfer; barcode/serial scan to add items; price-override audit; auto-apply best eligible offer; stock check inline (warn if item low/out); save-as-quotation; split payment (part cash/part transfer); print + WhatsApp invoice in one click; serial-number capture per product for warranty linkage.

---

### ADM-06 · Sales — Product Sale (guided sub-flow)
**APPEARS:** Select Product → Brand → Model → Price → Payment → Discount → Gift → Warranty toggle (Yes/No → auto reminder) → Installation toggle (Yes/No → auto-raise ticket + auto-assign technician, shown in a confirmation card); final summary (invoice + ticket + reminders created).
**ENHANCE:** auto-register warranty with serial + start/expiry and issue a digital warranty card (QR); schedule installation slot during sale; suggest matching accessories/spares; capture delivery vs installation addresses separately; auto-create the first AMC renewal reminder.

---

### ADM-07 · Invoice / Bill view
**APPEARS:** invoice header (GV Mart, GST no., invoice #), customer block, line-items table, totals (with-GST and without-GST lines), payment method + transaction ID, gift line, signature area, Print / Download PDF / Share-on-WhatsApp.
**ENHANCE:** GST-compliant tax invoice format with HSN codes; e-invoice/IRN ready; payment-status stamp (Paid/Partial/Due) + payment link for dues; credit-note/refund flow; email + WhatsApp delivery with read receipt; branded template.

---

### ADM-08 · Sales — Quotations
**APPEARS:** Lead→Quotation→Sales conversion ratio stat; table (lead/customer, items, amount, date, status Open/Converted/Lost); New Quotation (sale flow minus payment); convert-to-sale; filters.
**ENHANCE:** quotation validity/expiry date; auto follow-up reminders on open quotes; multiple versions/revisions; e-sign acceptance link; "why lost" reason capture to improve sales; template quotes.

---

### ADM-09 · Service — Tickets list
**APPEARS:** filters (status, priority, type Paid/Warranty/AMC, technician, date, area); table (Ticket#, Customer, Product/Brand/Model, Name-of-complaint, Type badge, Priority, Assigned tech, Appointment time, SLA status green/amber/red); kanban toggle by status; New Complaint; assign/reassign; pagination.
**ENHANCE:** live SLA countdown + auto-escalation on breach; map view of open tickets for routing; bulk-assign; repeat-complaint flag (same product serviced again soon = quality issue); "first-time-fix-rate" indicator; merge duplicate tickets.

---

### ADM-10 · Service — New Complaint (Stepper)
**APPEARS:** Customer (search/add); Equipment (Product→Brand→Model, auto-shown if owned); Complaint (Name-of-complaint = customer words; Nature-of-complaint = diagnosis, fill later); Type auto-detected (Paid/Warranty/AMC, Paid not freely selectable, shows purchase date + AMC expiry reason); Priority; Appointment (Always or Date&Time, 9:00–7:30, exceptions); create + optional auto-assign.
**ENHANCE:** photo/voice complaint capture (customer can send a clip in Tamil); known-issue/symptom picker that suggests likely nature + parts needed; auto-suggest parts to pre-load in technician's bag; channel field (call/WhatsApp/walk-in); attach previous related tickets.

---

### ADM-11 · Service — Appointments / Scheduling
**APPEARS:** calendar/timeline (left) + assignment panel (right); auto-assign engine card (availability + location + priority + customer availability); rules — no two simultaneous appointments per person, next unlocks only after current completes; per-technician day timeline with drag-to-reassign; repeat-caller/urgency flag; conflict warning.
**ENHANCE:** route-optimized day plan (cluster nearby jobs, minimize travel); skill/spare-availability-based matching (assign the tech who carries the needed part); buffer time per job by SOP duration; customer self-reschedule link; live capacity/heatmap by area; "auto-fill the day" optimizer button.

---

### ADM-12 · AMC & Warranty — list
**APPEARS:** tabs (AMC / Warranty); table (Customer, Product, Plan tier, Start, Expiry, Next scheduled service, Status chip Active/Due-soon/Expired); due-date filters; Sell AMC; highlight rows due within admin window.
**ENHANCE:** renewal pipeline view (kanban: Due→Contacted→Renewed→Lapsed); auto renewal reminders via WhatsApp with one-tap pay link; one-click bulk renewal campaign; revenue-at-risk total from lapsing AMCs; auto-create scheduled visits for the year on sale.

---

### ADM-13 · AMC — Plan builder (in Masters)
**APPEARS:** plan name (Gold/Silver/Platinum), No.-of-years selector, auto-calculated price (more years → less per year), included spares/products checklist, gift toggle, "service every 3 months" rule, save; note that warranty/AMC service cost = 0 but spare quantity still deducts inventory.
**ENHANCE:** define inclusions/exclusions and visit count per tier; per-plan profitability simulator (expected cost of included spares vs price); add-on coverage options; promotional pricing windows; clone-plan to create variants.

---

### ADM-14 · Technicians — List
**APPEARS:** table (Name, Phone, Status on-duty/off, Today's jobs, Today's revenue, Avg rating, KPI score); add technician; row→detail; filters.
**ENHANCE:** skill tags (RO/AC/Inverter certified); zone assignment; availability/leave status; document store (license, ID); per-tech spare-stock snapshot; quick "message all on-duty" action.

---

### ADM-15 · Technicians — Live Tracking (Map)
**APPEARS:** full map + side list; technician pins (green = on-route/on-time per per-km master; red box = off-route/idle 5–10 min with "stayed here X mins" tooltip); side list (current job, ETA vs expected, distance-reach indicator); per-km travel-time from master; empty state.
**ENHANCE:** breadcrumb route trail per technician; geofence-entry/exit log per customer (proves arrival/departure); idle/stop alerts pushed to Operation Admin; replay-the-day timeline scrubber; total km + travel-time report feeding fuel/petrol expense; live ETA shared to customer.

---

### ADM-16 · Technicians — Attendance
**APPEARS:** date picker; table (Technician, Check-in time, Inside-office ✓ geo-fence, Affirmation ✓, Pledge ✓, Meeting ✓, Late?); late rule (after 9:15 cannot tick meeting/affirmation/pledge; admin-editable cutoff); late hours feed payroll (hours-late ×2).
**ENHANCE:** selfie + geo check-in to prevent proxy attendance; leave/holiday calendar; monthly attendance % and punctuality trend; auto-link late hours to the salary deduction in ADM-24; shift configuration; regularization request flow.

---

### ADM-17 · Technicians — Spare Handover
**APPEARS:** technician-wise spare availability list (distribution bag); handover form with quantities; dual sign (admin + technician); allocation based on yesterday's cumulative invoices; given-vs-received history log.
**ENHANCE:** end-of-day van-stock reconciliation (issued − used = should-return; flag mismatches); barcode scan handover; low-bag-stock alert before dispatch; auto-suggest top-up based on today's scheduled jobs and their likely parts; defective/returned-part tracking.

---

### ADM-18 · Inventory — Products & Spares
**APPEARS:** tabs (Products/Spares); table (item, brand, model, current stock, min-stock threshold, reorder qty, supplier(s), status In-stock/Low/Out); inline threshold edit; low-stock highlight.
**ENHANCE:** stock valuation + ageing; batch/serial & expiry tracking; sales-velocity-based dynamic reorder point (not just fixed 10); stock movement ledger; multi-location stock (warehouse vs van); barcode labels; dead-stock report.

---

### ADM-19 · Suppliers — list
**APPEARS:** table (Supplier, products provided, price per product, contact/WhatsApp); link inventory item → supplier(s); cheapest-supplier marker per product.
**ENHANCE:** supplier rating (price, lead time, quality); price-history per product; lead-time tracking to time reorders; multiple price tiers/MOQ; payment-terms and outstanding-payable tracking; preferred-supplier rules.

---

### ADM-20 · Purchase — Purchase Orders
**APPEARS:** PO list (PO#, supplier, items, qty, status Draft/Sent/Received); auto-PO panel (stock ≤ min → draft PO to cheapest supplier → send on WhatsApp); manual Create PO.
**ENHANCE:** PO approval workflow above a value; partial-receipt handling; auto goods-received → stock update; PO vs bill matching; expected-delivery tracking + overdue PO alerts; consolidate multiple low items into one PO per supplier.

---

### ADM-21 · Purchase — Bill Entry
**APPEARS:** entry form where previous bill + supplier auto-default; line items, amounts, GST; saves to inventory + expenses.
**ENHANCE:** scan/upload supplier bill with OCR auto-fill; three-way match (PO ↔ goods received ↔ bill); duplicate-bill detection; auto-post to expenses + GST input-credit ledger; attach bill image.

---

### ADM-22 · Automation — Leads
**APPEARS:** lead table (name, source, enquiry type, status, owner/technician reference); source-of-lead field; customer-reference→points (per-point value from master, min 50, 1000 points accumulated reflects as reward); lead detail (conversation + next action).
**ENHANCE:** full Kanban pipeline (New→Contacted→Quoted→Won/Lost) with drag; lead scoring/priority; auto-assign + SLA on first response; aging alerts on stale leads; source-wise conversion analytics (which channel pays off); referral wallet view tied to the points system; auto-nurture sequences.

---

### ADM-23 · Automation — WhatsApp / AI flow builder
**APPEARS:** visual rule builder (trigger = enquiry about online/price/quality/customization/water-premium/budget → action = send matching video/quotation/website link → close); AI-agent toggle; video library mapped to topics; "flow set by admin."
**ENHANCE:** drag-drop node canvas with branches/conditions; template manager (WhatsApp-approved templates); fallback "talk to human" handoff; A/B test variants; analytics per node (sent/opened/replied/converted); office-hours + auto-reply; multilingual message variants.

---

### ADM-24 · HR — Salary
**APPEARS:** per-technician salary card (revenue-based base e.g. ₹5–6k/day→₹2,000, +₹5,000/month per extra ₹1k/day; late deduction hours×2; net); month selector; payslip export.
**ENHANCE:** auto-pull attendance + revenue + incentives + late deductions into one computed payslip; advances/loans tracking; PF/ESI/tax fields; bulk payslip generation + WhatsApp delivery; bank-transfer file export; salary-cost vs revenue ratio.

---

### ADM-25 · HR — Incentives (Incentive Master)
**APPEARS:** rule rows for excess service income, sales income, reviews; thresholds + amounts; per-technician earned-incentive preview.
**ENHANCE:** tiered/slab incentives; team vs individual targets; real-time "incentive earned so far this month" shown to each technician in their app; simulator ("if you do X more jobs you earn Y"); cap/floor controls.

---

### ADM-26 · HR — Rewards
**APPEARS:** monthly categories (On-time attendance, Highest reviews min-51, Highest revenue min-₹1,50,000); winner display; log of reward given (admin logs after rewarding).
**ENHANCE:** automated badge/streak system; public recognition feed in technician app; redeemable points store; runner-up tiers; quarterly/annual awards; fairness check (auto-exclude ineligible below thresholds).

---

### ADM-27 · Reports — Sales & Service
**APPEARS:** filterable blocks — No. of sales calls; Product vs Spare vs AMC ratio; technician-wise service counts; average value per service call; total revenue; include-technician-report; export.
**ENHANCE:** scheduled auto-email/WhatsApp reports (daily/weekly); drill-down from any chart to raw rows; first-time-fix-rate, repeat-complaint-rate, avg-resolution-time; area/zone heatmaps; cohort/retention view; custom report builder.

---

### ADM-28 · Reports — P&L and Expenses
**APPEARS:** P&L statement with With-GST/Without-GST toggle; expense breakdown (Marketing, Stationery, Salary, Petrol); clear net-profit; date range; data-safety note; Excel export.
**ENHANCE:** category-wise + product-line-wise profitability; month-over-month and budget-vs-actual; cash-flow view; receivables/payables aging; GST summary (output − input); auto-pull salary/fuel/purchase expenses; drill to source documents.

---

### ADM-29 · Reports — Performance scoreboard (KRA/KPI)
**APPEARS:** leaderboard table with KRA/KPI columns (jobs done, on-time %, revenue, reviews, conversion); Operation Admin KPI (complaints within 24h / same-day); Sales Admin KPI (calls-ratio 40%/50% → incentive); badges for top performers.
**ENHANCE:** weighted composite score with admin-configurable weights; trend sparkline per person; target vs actual gauges; auto-flag underperformers for coaching; gamified ranks; team rollups; export to payroll for incentive calc.

---

### ADM-30 · Masters / Settings
**APPEARS:** sub-pages — Product/Brand/Model masters; AMC plan builder; Warranty master; Incentive master; per-km travel-time master; gift-threshold settings; discount limits (tech ≤5%, 5–10% admin approval, never >10%); Users & Roles; working-hours & geo-fence radius; reward thresholds.
**ENHANCE:** full audit trail on every master change; effective-dated changes (price changes apply from a date); import/export masters; sandbox to preview impact of a price change; granular permission matrix per role; backup/restore.

---

### ADM-31 · My Workspace (Operation / Sales Admin)
**APPEARS:** to-do checklist ("manual diary"): completed items close end-of-day, unfinished roll to next day; Notifications, Follow-ups, Reminders feed; AI confirmation-call card (agent calls customer to confirm availability before technician departs — one check before).
**ENHANCE:** auto-generated tasks from system events (overdue ticket → task); priority/due-time on tasks; recurring tasks; assign tasks to others; snooze/reschedule; daily-summary digest at day-end; calendar view.

---

## 5. TECHNICIAN APP — screens (mobile)

> Shell: bottom tabs `Home · Map · Attendance · History · Profile`. Big targets, outdoor-readable, offline-first, dark-mode option. The on-site flow is a full-screen stepper launched from a job card.

---

### TECH-00 · Login
**APPEARS:** logo, phone + password/OTP, big login button, language switch, forgot-password.
**ENHANCE:** biometric/PIN unlock; stay-logged-in; offline login with cached credentials.

---

### TECH-01 · Attendance (geo-fenced)
**APPEARS:** "Mark Attendance" button disabled unless GPS inside office geo-fence; success state; sequential checklist Affirmation ✓ / Pledge ✓ / Meeting ✓; after-9:15 lock with banner; today's status.
**ENHANCE:** selfie check-in (anti-proxy); shows distance-to-office if outside fence; apply-leave button; punctuality streak; today's job count preview right after check-in.

---

### TECH-02 · Spare receipt & sign
**APPEARS:** allocated spares list with qty; technician signature pad; admin signature shown; Confirm-received; allocation based on yesterday's invoices.
**ENHANCE:** barcode-scan each part to confirm; flag shortage/mismatch on the spot; running van-stock balance; "request extra part" before leaving.

---

### TECH-03 · Home (Today's jobs)
**APPEARS:** ordered job cards (first dispatch first): customer name, area, complaint name, type badge (Paid/Warranty/AMC), priority, appointment time; Start/Navigate per card; remaining-jobs count; "go to first work" toggle.
**ENHANCE:** route-optimized job order with total distance/time; today's earnings/incentive ticker; one-tap call/WhatsApp customer from the card; reschedule-request; weather/traffic note; pull-to-refresh sync.

---

### TECH-04 · Map / Navigation
**APPEARS:** route from current location (or GV Mart) to customer; distance-reach indicator (green on-time / red off-route or idle); ETA vs expected; "I've arrived" button (starts productivity timer).
**ENHANCE:** open in Google Maps/turn-by-turn; auto-detect arrival via geofence (no manual tap needed); share live ETA to customer via WhatsApp; off-route nudge; multi-stop routing for the day.

---

### TECH-05 · Customer search & call
**APPEARS:** search by address (name + contact shown); tap phone → initiates call; "Navigate to location"; shows only the Service/Product relevant to this job.
**ENHANCE:** masked-number calling (privacy); WhatsApp shortcut; "running late, notify customer" one-tap; landmark photo/notes from previous visits.

---

### TECH-06 · Job detail / Customer history
**APPEARS:** previous service history timeline (scannable); current type (Paid/Warranty/AMC); product–brand–model–complaint–appointment time; customer availability; costing rule (Paid → qty & cost from master; Warranty/AMC → cost ₹0 but qty captured).
**ENHANCE:** quick-glance "what was done last time + parts used"; known recurring issue flag; warranty/AMC coverage summary card; suggested parts for this complaint; customer preferred language + notes (e.g. "has a dog").

---

### TECH-07 · On-site service (full-screen Stepper)
**APPEARS / steps:**
1. Productivity timer (auto-started on arrival).
2. Before-image uploader (current condition).
3. SOP checklist — step-by-step per process/part, each with fixed expected time; tick done.
4. After-image uploader.
5. Spares used — select by search **or voice**; whatever is consumed.
6. Charges — service charge (paid) / ₹0 (warranty/AMC); discount slider capped at 5% (5–10% → "needs admin approval"; >10% blocked).
7. RO checklist (if RO): TDS before, TDS after, Tank cleaned (Yes/No), Product explained (Yes/No), Name of client.
8. Create invoice → preview.
9. Signatures — technician + customer sign on screen.
10. Payment — Cash/Transfer (+ Transaction ID & description if transfer).
- Enquiry capture: "Generate Enquiry" (Service/Product/AMC) → logged as a lead referenced to his name (for incentive).
**ENHANCE:** geotag+timestamp watermark on photos; OTP from customer to close the job; UPI QR for transfer; voice-to-text notes in Tamil; offline save + auto-sync; over-time alert if a step exceeds its SOP time; auto-suggest parts from the diagnosis; digital invoice sent to customer's WhatsApp instantly; "needs revisit" flag with reason; feedback that low-stock parts auto-trigger reorder.

---

### TECH-08 · Rating prompt (customer signs on tech's phone)
**APPEARS:** star rating + short review by customer; if 5 stars → "Leave a Google review" button; below 5 → hidden.
**ENHANCE:** deep-link straight to the Google review page pre-filled; capture low-rating reason internally (and alert Operation Admin); thank-you screen; tie 5-star to technician incentive automatically.

---

### TECH-09 · History
**APPEARS:** past jobs list with filters (date, type); each opens read-only TECH-06/07 summary.
**ENHANCE:** personal stats (jobs, avg rating, on-time %, earnings); search by customer/product; export day-sheet.

---

### TECH-10 · Profile
**APPEARS:** name, photo, today's earnings/incentive preview, rating, KPI score, logout.
**ENHANCE:** month-to-date incentive + target progress; rewards/badges earned; payslip view; van-stock summary; help/support + raise-issue.

---

## 6. CUSTOMER APP — screens (mobile)

> Shell: bottom tabs `Home · My Products · Bookings · Profile`. Simple, friendly, guided.

---

### CUST-00 · Login / Register
**APPEARS:** phone + OTP; first-use capture of name + address (reuse ADM-04 fields + autocomplete).
**ENHANCE:** WhatsApp-based OTP; social login; auto-detect location for address; skip-and-browse mode.

---

### CUST-01 · Home
**APPEARS:** greeting; address bar at top (fill/confirm first); four action tiles — Service Booking, Spare Enquiry, Product Enquiry, AMC Enquiry; AMC/warranty status cards for owned products.
**ENHANCE:** "next service due" reminder banner with book-now; active-ticket live status + technician ETA; offers/festival banners; loyalty-points balance; quick re-book of last service.

---

### CUST-02 · Service Booking (guided chat/stepper)
**APPEARS:** chat-style question set → pick Product→Model→Brand (auto-shown if owned; if unknown, skip and it's added to a service enquiry automatically); describe issue; pick slot; confirmation.
**ENHANCE:** photo/voice issue description (Tamil); show likely visit charge upfront for paid; live slot availability; auto-detect coverage (free if under warranty/AMC); add-to-calendar; reschedule/cancel.

---

### CUST-03 · AMC Enquiry / Book
**APPEARS:** next service/warranty/AMC details (due date + what's covered); booking enabled only when due date is near (admin window); plan tiers (Gold/Silver/Platinum) with prices; confirm.
**ENHANCE:** in-app renewal with UPI payment; plan-comparison table; savings-vs-paid-service calculator; auto-reminders before expiry; digital AMC card (QR).

---

### CUST-04 · Product Enquiry
**APPEARS:** topic chips (online/price/quality/customization/water-premium/budget); selecting a topic auto-sends the matching video or website link (via WhatsApp/AI flow); "Request quotation" → creates lead; close option.
**ENHANCE:** in-app product catalog with specs/photos; EMI/finance options; compare products; "request callback" slot; chat with AI agent; share-with-family.

---

### CUST-05 · Spare Enquiry
**APPEARS:** product/model selector; part description (text or photo); submit → creates enquiry/lead.
**ENHANCE:** part catalog with images + price; "is my part in stock" check; reorder a previously bought part; doorstep-delivery option.

---

### CUST-06 · My Products
**APPEARS:** cards per product (brand/model, purchase date, warranty status, AMC status + next service date, Book-service shortcut).
**ENHANCE:** register a product via serial/QR scan to start warranty; service-history per product; manuals/how-to videos; usage tips/reminders (e.g. "change filter").

---

### CUST-07 · Bookings / History
**APPEARS:** past + upcoming bookings with status; tap for detail (technician, before/after images, invoice, rating).
**ENHANCE:** live tracking of on-the-way technician with ETA + name/photo; download invoice; rebook/repeat; raise complaint on a past job; running spend summary.

---

### CUST-08 · Profile
**APPEARS:** name, address (editable, "moved? update address", family members up to 5), contact, logout.
**ENHANCE:** multiple saved addresses; language preference; notification preferences; loyalty/referral wallet + invite-and-earn (feeds the reference-points system); saved payment methods.

---

## 7. Brand-new pages worth adding (not in the notes, but high value)

These plug obvious gaps and elevate the product.

- **ADM-32 · Notifications Center** — unified inbox of all system alerts (stock-outs, SLA breaches, AMC renewals, approvals), with filters and mark-as-read.
- **ADM-33 · Approvals Queue** — one place for the admin to approve discounts (5–10%), high-value POs, price overrides, leave requests.
- **ADM-34 · Complaints & Escalations** — track unhappy customers / low ratings / repeat issues separately, with an escalation ladder and resolution SLA.
- **ADM-35 · Campaign Manager** — build WhatsApp/SMS campaigns to customer segments (AMC due, dormant, festival offers); track sent/opened/converted.
- **ADM-36 · Feedback / NPS Dashboard** — aggregate ratings and reviews, trend over time, technician-wise and area-wise satisfaction.
- **ADM-37 · Returns / Replacement** — handle defective product/spare returns, warranty claims to suppliers, and replacements with inventory effect.
- **ADM-38 · Audit Log / Activity** — searchable record of every important action (supports "data safety / secured").
- **CUST-09 · Refer & Earn** — shareable referral link/code that credits the reference-points wallet on a successful sale.
- **CUST-10 · Support / Help Center** — FAQs, how-to videos, chat with AI agent, raise a complaint.
- **TECH-11 · Daily Day-Sheet / Summary** — end-of-day recap (jobs done, collected cash, parts used, earnings) with one-tap submit/reconcile.

---

## 8. Shared component library (define once, reuse)

| Component | Behavior |
|---|---|
| Search-autocomplete | Suggests existing matches as you type (e.g. "2" → all door-nos containing 2). |
| Status badge/chip | Paid · Warranty · AMC · On-time(green) · Late(red) · Pending(amber) · In/Low/Out-of-stock. |
| Data table | Sort, filter, row actions, bulk export, pagination, empty state. |
| KPI stat card | Label, big number, trend arrow + delta, period toggle, click-through. |
| Stepper | Numbered steps, per-step validation gate, right-rail summary. |
| Timeline/history list | Dated entries with type badges. |
| Map view | Status pins (green/red), route line, idle/off-route red box + tooltip, breadcrumb trail. |
| Image uploader | Camera capture, before/after, geotag+timestamp watermark, thumbnails. |
| Signature pad | Capture/clear; dual-sign mode. |
| Voice input | Mic on spare-select / complaint / notes (Tamil + English). |
| Rating stars | 1–5; conditional Google-review CTA at 5. |
| Discount control | Caps + needs-approval + blocked states. |
| Toggle / Yes-No | Warranty, Installation, Tank-clean, etc. |
| Payment block | Cash/Transfer; UPI QR + payment link; transaction-ID capture. |
| Notification/toast + alerts feed | Success/warning/error + persistent inbox. |
| Empty / loading / error states | Standard for every list and form. |

---

## 9. Suggested design order (phases)

1. **Foundations** — design system + shells/nav for all 3 surfaces + shared components + global enhancements.
2. **Customer core** — ADM-02/03/04.
3. **Sales** — ADM-05/06/07/08.
4. **Service** — ADM-09/10/11 + AMC/Warranty (ADM-12/13).
5. **Technician App** — TECH-01→08 (+ TECH-11). The field flow is the heart of the product.
6. **Customer App** — CUST-01→07 (+ CUST-09/10).
7. **Inventory & Purchase** — ADM-18/19/20/21.
8. **Automation** — ADM-22/23 + customer enquiry flows.
9. **HR, Reports, Masters, new pages** — ADM-24→38.

---

### One-line summary
Three connected apps — an **Admin Web** command center, a **Technician field app**, and a **Customer self-service app** — sharing one design system; each page here lists everything it must show plus enhancements that turn a faithful build of the notes into a genuinely strong product.
