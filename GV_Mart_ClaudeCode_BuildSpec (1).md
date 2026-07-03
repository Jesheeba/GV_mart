# GV Mart — Claude Code Build Spec

A phased, ready-to-paste implementation guide for building the GV Mart sales + service + technician management system. Hand this to **Claude Code** one phase at a time.

> Companion file: `GV_Mart_ClaudeDesign_Workflow_Complete.md` (screen IDs like `ADM-05`, `TECH-07` are referenced here). Use that for the *look* of each screen; use this for the *build*.

---

## ⚠️ AUTHORITY & v2.2 VALUE OVERRIDES (read first — these win over everything below)

**The client-signed `GVMart-Requirement-Confirmation v2.2.pdf` is the source of truth.** Wherever any number, rule, or example later in this document conflicts with v2.2, **use the v2.2 value below.**

| Topic | ❌ Old text in this doc | ✅ Use this (v2.2) |
|---|---|---|
| Inventory | reorder 50 / various min | **min stock = 10, reorder qty = 10** (seed all items 10/10) |
| Travel time (`per_km_minutes`) | 1.5–2.0 min/km | **1 km = 5 min** (`per_km_minutes = 5`) |
| Geofence | radius / metres / feet figure | **"inside office only"** — never show a distance figure to users |
| Salary | fixed bands ₹15k/₹20k | **revenue-based, admin-set, NO fixed ₹** — all slabs configurable in master |
| Incentive rates | 1–1.5%, ₹25/₹50 | **admin-set in the incentive master**, no hardcoded rates |
| Customer review link | 5★ only | **shows only at 4.5★ or 5★** (customer side); technician earns incentive per Google review received, admin-set value |
| Lunch | — | **30 min allowed; red if over 45 min** |
| Referral points | "1000 points", "1 pt = ₹1" | **value per point admin-set, minimum 50, reflect "as agreed"** — no fixed conversion |
| Payments | "UPI QR / payment link" in staff billing | **Staff billing = manual transaction-ID + description only (NO gateway).** Real payment gateway lives **only in the Customer App** for AMC / online payment |
| Attendance ticks | — | **Affirmation → Pledge → Meeting**, locked after **09:15** (admin-editable) |

**Scope guard (do NOT build — not in signed v2.2):** SOP-time master screen, complaint-name master, zone/area master, vendor price-history, GST-filing checklist, bank-payment-tracking screen, availability-exception windows, first-dispatch 10–50 ft trigger, OTP-to-close, selfie-attendance, and any fixed salary/incentive/referral numbers. Anything beyond v2.2 is a change request.

**Build order = client-approved v2.2 stages:** (1) core sales/billing/service-logging/inventory → (2) technician app (attendance, live tracking, photos, checklist, on-spot billing, call tracking) → (3) AMC/Warranty automation + customer app (admin-editable enquiry flows) → (4) salary/incentives/rewards → (5) WhatsApp automation, auto-POs, full reports.

---

## 0. How to use this with Claude Code

1. Start a Claude Code session in an empty repo.
2. Paste **Section 1–5 once** at the start of the session (context: goal, stack, roles, structure, data model).
3. Then paste **one Phase prompt at a time** (Section 6). Let it finish, review, commit, then move to the next phase.
4. After each phase, run the **Definition of Done** checks before continuing.

**Working rule for Claude Code (tell it this up front):** *Audit before building — read existing files and the schema before writing new code. Keep each module self-contained. Use TypeScript everywhere, server actions for mutations, Zod for validation, and Supabase RLS for every table. Don't invent columns; follow the schema in Section 5.*

---

## 1. Project goal

Build one system with **three role-based experiences** sharing a single codebase and database:

- **Admin Web** (desktop) — owner / operation admin / sales admin run everything.
- **Technician App** (mobile/PWA) — attendance, assigned jobs, on-site service, invoicing. Offline-first.
- **Customer App** (mobile/PWA) — book service, raise enquiries, view AMC/warranty.

Business: sells + services RO purifiers, ACs, inverters, batteries. Revenue = product sales + spares + paid service + AMC contracts. Field technicians travel to homes (attendance, routing, live tracking matter).

---

## 2. Tech stack & architecture

| Layer | Choice |
|---|---|
| Framework | **Next.js 15** (App Router), **TypeScript** |
| DB / Auth / Storage / Realtime | **Supabase** (Postgres + RLS, Auth, Storage, Realtime) |
| Styling | **Tailwind CSS** + **shadcn/ui** |
| Forms / validation | react-hook-form + **Zod** |
| Data fetching | Server Components + **Server Actions**; TanStack Query for client-side live data (tracking, lists) |
| Maps / geo | Google Maps JS API (tracking, geocoding, geo-fence) |
| Messaging | **WhatsApp Cloud API** (notifications, automation) |
| Mobile | **PWA** (installable, offline via service worker + IndexedDB queue). Wrap with **Capacitor** later if a store build is needed. |
| State (offline queue) | IndexedDB (Dexie) for technician offline actions, synced to Supabase on reconnect |
| Charts | Recharts |
| Deploy | Vercel (web) + Supabase cloud |

**Single app, three shells, role-routed:**
```
/(auth)              -> login, register
/(admin)/...         -> Admin Web  (role: master | operation_admin | sales_admin)
/(technician)/...    -> Technician App (role: technician)
/(customer)/...      -> Customer App (role: customer)
```
Middleware reads the user's role and redirects to the right shell after login.

**Multi-tenant ready:** every business table carries `org_id`. For GV Mart it's a single org now, but this keeps it pluggable into a multi-tenant CRM later. All RLS policies filter by `org_id` + role.

---

## 3. Roles & access model

**Each role is a SEPARATE LOGIN with its own permissions — not a UI toggle.** The Owner/Operations/Sales switcher seen in the design mockups exists only to *preview* the three dashboards in one place; in the real app there is **no role switcher**. A user logs in, their `role` is read from `profiles`, and they see **only** the dashboard and menu items their role allows. A Sales Admin cannot see the Owner view; an Operation Admin cannot open payroll, etc.

| Role | Logs in and sees | Cannot access |
|---|---|---|
| `master` (Owner/Admin) | Everything: full dashboard, all modules, masters, approvals, payroll, reports | — |
| `operation_admin` | Operations dashboard, Service/Tickets, Scheduling, Technicians, Spare Handover, My Workspace (to-do), Complaints/Escalations | Masters, Payroll, P&L, Sales pricing, Approvals above limit |
| `sales_admin` | Sales dashboard, New Sale, Quotations, Leads pipeline, Customers, Campaigns | Service ops, Technician payroll, Masters, P&L |
| `technician` | Technician App only: own attendance, own assigned jobs, on-site service, own profile/earnings | Any other technician's data, all admin web |
| `customer` | Customer App only: own profile, own products, own bookings/enquiries | All staff/admin areas |

**On login, redirect by role:**
- `master` / `operation_admin` / `sales_admin` → admin shell, but the **landing dashboard and the visible sidebar items differ by role** (gate each nav item and each dashboard variant on `role`). No switcher in the top bar.
- `technician` → Technician App shell.
- `customer` → Customer App shell.

**RLS principle:** staff roles scoped to `org_id` *and* gated per-module by role; `technician` scoped to rows assigned to them; `customer` scoped to their own `customer_id`. Enforce on the server (middleware + RLS + per-action role checks), never only in the UI.

> Design-vs-build note: in the `.dc.html` mockups the role switcher is fine for previewing. When Claude Code builds the app, **drop the switcher** and implement the role-gated separate-login behaviour above.

---

## 4. Folder structure

```
src/
  app/
    (auth)/login/ register/
    (admin)/dashboard/ customers/ sales/ service/ amc/ technicians/
            inventory/ suppliers/ automation/ hr/ reports/ masters/ workspace/
    (technician)/home/ map/ attendance/ history/ profile/ job/[id]/
    (customer)/home/ products/ bookings/ profile/ book/ enquiry/
    api/ (webhooks: whatsapp, etc.)
  components/
    ui/            # shadcn primitives
    shared/        # table, kpi-card, stepper, status-badge, signature-pad,
                   # image-uploader, map-view, voice-input, autocomplete...
    admin/ technician/ customer/
  lib/
    supabase/      # server + client + middleware helpers
    actions/       # server actions per module
    validation/    # zod schemas per module
    offline/       # dexie queue + sync
    whatsapp/ maps/ utils/
  hooks/
  types/           # generated DB types + domain types
supabase/
  migrations/      # SQL
  seed/
```

---

## 5. Data model (Supabase / Postgres)

Concise schema — columns listed; `id uuid pk`, `org_id`, `created_at`, `updated_at` implied on all unless noted. Tell Claude Code to generate full SQL migrations + RLS from this.

**Identity & org**
- `organizations` — name, gst_no, settings(jsonb)
- `profiles` — links `auth.users`; full_name, phone, role, photo_url, language, is_active
- `technicians` — profile_id fk, skills(text[]), zone, is_on_duty

**Customers**
- `customers` — primary_profile? , name, mobile, profession, source, tags(text[]), notes
- `customer_members` — customer_id fk, name, mobile, is_primary  (max 5 enforced in app + check)
- `addresses` — customer_id fk, door_no, flat_no, street_cross, area, pincode, landmark, district, state, lat, lng, address_type(residential|commercial), ownership(own|rental), is_primary

**Catalog & inventory**
- `brands` — name, category(ro|ac|inverter|battery)
- `models` — brand_id fk, name, type(window|split|domestic|commercial|marine|...)
- `products` — brand_id, model_id, name, category, price, hsn_code
- `spares` — name, sku, price, hsn_code
- `inventory` — item_type(product|spare), item_id, stock_qty, min_stock, reorder_qty, location(warehouse|van)
- `inventory_movements` — item_type, item_id, change_qty, reason, ref_id

**Suppliers & purchase**
- `suppliers` — name, contact, whatsapp, rating
- `supplier_products` — supplier_id, item_type, item_id, price, lead_time_days, is_preferred
- `purchase_orders` — supplier_id, status(draft|sent|received), total, sent_channel
- `po_items` — po_id, item_type, item_id, qty, price
- `purchase_bills` — supplier_id, po_id?, amount, gst, bill_image_url

**Sales**
- `quotations` — customer_id|lead_id, status(open|converted|lost), valid_until, total, lost_reason
- `quotation_items` — quotation_id, item_type, item_id, qty, price
- `invoices` — customer_id, type(product|spare|amc), subtotal, discount, gst, total, payment_method(cash|transfer), txn_id, payment_status, gift_id?
- `invoice_items` — invoice_id, item_type, item_id, qty, price, discount
- `gifts` — name, threshold_amount  (master)  + `gift_logs` — invoice_id, gift_id

**Service**
- `service_tickets` — customer_id, address_id, product_id, brand_id, model_id, name_of_complaint, nature_of_complaint, type(paid|warranty|amc), priority(very_urgent|urgent|normal), status(open|assigned|in_progress|completed|cancelled), channel, sla_due_at
- `appointments` — ticket_id, technician_id, scheduled_at, mode(always|datetime), status
- `service_visits` — ticket_id, technician_id, timer_start, timer_end, before_image_url, after_image_url, service_charge, discount, otp_verified, needs_revisit, notes
- `service_sop_steps` — visit_id, step_name, expected_minutes, done_at
- `service_spares_used` — visit_id, spare_id, qty, cost
- `ro_checklists` — visit_id, tds_before, tds_after, tank_cleaned(bool), product_explained(bool), client_name
- `ratings` — visit_id, stars, review, google_review_clicked

**AMC & warranty**
- `amc_plans` — name(gold|silver|platinum), years, price, inclusions(jsonb), gift, visits_per_year  (master)
- `amc_contracts` — customer_id, product_id, plan_id, start_date, expiry_date, status(active|due_soon|expired), next_service_date
- `warranties` — customer_id, product_id, serial_no, start_date, expiry_date

**Technician ops**
- `attendance` — technician_id, date, check_in_at, inside_geofence(bool), affirmation(bool), pledge(bool), meeting(bool), is_late, selfie_url
- `spare_handovers` — technician_id, date, admin_sign_url, tech_sign_url, status
- `spare_handover_items` — handover_id, spare_id, qty_given, qty_returned
- `technician_locations` — technician_id, lat, lng, recorded_at  (realtime track)

**Leads & automation**
- `leads` — customer_id?, name, mobile, source, enquiry_type(online|price|quality|customization|water_premium|budget), status(new|contacted|quoted|won|lost), owner_id(reference technician), score
- `lead_activities` — lead_id, type, note, at
- `automation_flows` — trigger(enquiry_type), action(send_video|quotation|link), asset_url, is_active
- `video_library` — topic, url
- `referral_points` — customer_id, points, reason, ref_id   (per-point value in settings; min 50)

**HR / finance**
- `incentive_rules` — type(service_income|sales_income|review), threshold, amount  (master)
- `incentives_earned` — technician_id, rule_id, amount, period
- `rewards` — category(attendance|highest_review|highest_revenue), period, winner_id, given_by, given_at, note
- `salaries` — technician_id, period, base, revenue_component, late_deduction, incentives, net
- `expenses` — category(marketing|stationery|salary|petrol|purchase|other), amount, ref_id, date

**System**
- `settings` (masters) — key/value: per_km_minutes, geofence_radius_m, work_start, work_end, late_cutoff(09:15), discount_tech_max(5), discount_admin_max(10), amc_book_window_days, referral_point_value, gift_thresholds
- `approvals` — type(discount|po|price_override|leave), ref_id, requested_by, status, approver_id
- `notifications` — user_id|role, type, title, body, is_read, ref_id
- `audit_log` — actor_id, action, table_name, row_id, before(jsonb), after(jsonb)
- `tasks` (workspace to-do) — assignee_id, title, due_date, status(open|done|rolled), source

---

## 6. Build phases (paste one at a time)

Each phase: **Goal**, **Tables/Screens**, and a **Claude Code prompt** to paste verbatim.

---

### PHASE 0 — Project setup

**Goal:** Working Next.js 15 + TS + Supabase + Tailwind + shadcn skeleton with PWA shell and Supabase clients.

**Prompt:**
> Set up a new Next.js 15 (App Router, TypeScript) project. Add Tailwind CSS and initialize shadcn/ui. Install and configure Supabase (`@supabase/ssr`) with three helpers in `src/lib/supabase/`: a server client, a browser client, and middleware for session refresh. Add `.env.example` with `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, Google Maps key, and WhatsApp Cloud API vars. Configure the app as an installable PWA (manifest + service worker) with an offline fallback. Create the folder structure from Section 4 (empty route groups `(auth)`, `(admin)`, `(technician)`, `(customer)` with placeholder pages). Add a root layout, a theme provider, and the teal design tokens from the design workflow file as CSS variables. Set up ESLint/Prettier. Do not build features yet — just a clean, runnable skeleton. Print setup/run instructions when done.

**Definition of Done:** `npm run dev` runs; PWA installable; Supabase clients import without error.

---

### PHASE 1 — Database schema & RLS

**Goal:** All tables from Section 5 as migrations, with RLS and generated TS types.

**Prompt:**
> Using the data model in Section 5 of the build spec, generate Supabase SQL migrations under `supabase/migrations/` creating every table with appropriate types, foreign keys, indexes, `org_id`, and `created_at/updated_at` triggers. Add a `customer_members` check to limit 5 per customer (enforce in app too). Enable Row Level Security on every table and write policies per the role model in Section 3: staff roles (`master`, `operation_admin`, `sales_admin`) scoped by `org_id`; `technician` limited to rows assigned to them (attendance, appointments, visits, handovers, own profile); `customer` limited to their own `customer_id`. Add a `settings` seed row with the defaults (per_km_minutes=5, late_cutoff='09:15', discount_tech_max=5, discount_admin_max=10, etc.). Create a small seed script for one org, one master user, a few brands/models/products/spares, and two technicians. Generate TypeScript DB types into `src/types/database.ts`. Verify migrations apply cleanly.

**DoD:** Migrations apply; RLS on; types generated; seed runs.

---

### PHASE 2 — Auth & role-based shells

**Goal:** Login/register, role routing, and the three app shells.

**Screens:** `ADM-00`, app shells for Admin sidebar, Technician tabs, Customer tabs.

**Prompt:**
> Build authentication with Supabase Auth: `(auth)/login` and `(auth)/register` using shadcn forms + Zod. After login, read the user's `role` from `profiles` and redirect: master/operation_admin/sales_admin → admin shell, technician → `/home`, customer → `/home` (customer group). **Implement SEPARATE role-based logins, not a UI toggle:** there is no Owner/Operations/Sales switcher in the app. Instead, gate the landing dashboard and every sidebar item on `role` — master sees all; operation_admin sees Operations dashboard + Service/Scheduling/Technicians/Workspace; sales_admin sees Sales dashboard + Sales/Quotations/Leads/Customers. Enforce route protection in middleware AND rely on RLS; never trust the client. Build the three shells: **Admin** = collapsible left icon sidebar (items filtered by role) + top bar (global search, notifications bell, user menu — no role switcher). **Technician** = bottom tabs (Home, Map, Attendance, History, Profile). **Customer** = bottom tabs (Home, My Products, Bookings, Profile). Add an English/Tamil language toggle in the top bar. Pages can be placeholders for now.

**DoD:** master/operation_admin/sales_admin each log in to a *different* dashboard with a *different* sidebar; technician and customer land in their own apps; no role switcher exists; unauthorized routes redirect.

---

### PHASE 3 — Customers module

**Goal:** Full customer CRUD with members, addresses, autocomplete.

**Screens:** `ADM-02`, `ADM-03`, `ADM-04`.

**Prompt:**
> Build the Customers module in the admin group. **List (`ADM-02`):** searchable, filterable data table (search by mobile/name with autocomplete; filters: address type, area/PIN, has-AMC, has-warranty) using a reusable `<DataTable>`. **Detail (`ADM-03`):** profile header (contact, profession, address with map thumbnail via Google geocoding, address-type chips), family-members panel (max 5, set-primary, add/remove), tabs for Products / Service history (timeline) / Invoices / Leads, and action buttons (New Sale, New Ticket, Sell AMC, Edit, Move-member-out→new customer). **Add/Edit (`ADM-04`):** a 2-step stepper — Step 1 People (Name+Mobile pairs, "+" to add up to 5, Profession), Step 2 Address (Door/Flat/Street-Cross/Area/PIN/Landmark with autocomplete against existing rows, address-type + ownership selectors, auto-fill district/state from PIN via geocoding, map pin confirm). Use server actions + Zod, write to `customers`, `customer_members`, `addresses`. Add live duplicate-mobile detection. Build reusable `<SearchAutocomplete>` and `<AddressForm>` components.

**DoD:** Create/edit/search/view customers; members capped at 5; addresses geocode; duplicates flagged.

---

### PHASE 4 — Masters, catalog & inventory

**Goal:** Product/brand/model + spares + stock + suppliers; core settings.

**Screens:** `ADM-18`, `ADM-19`, `ADM-30` (relevant masters).

**Prompt:**
> Build Masters and Inventory. **Masters (`ADM-30`):** CRUD for brands, models, products (with price), spares, gifts/thresholds, AMC plans, warranty defaults, incentive rules, and the `settings` table (per-km time, geofence radius, work hours, late cutoff, discount limits, AMC booking window, referral point value). Every master change writes to `audit_log`. **Inventory (`ADM-18`):** tabs Products/Spares with current stock, min-stock, reorder-qty, supplier, status chip (In/Low/Out), inline threshold edit; writing stock changes logs to `inventory_movements`. **Suppliers (`ADM-19`):** supplier CRUD, link supplier→items with price + lead time, mark cheapest/preferred per item. Use server actions + Zod + RLS (master only for masters).

**DoD:** Can manage all masters; inventory reflects stock; suppliers linked to items; audit log records changes.

---

### PHASE 5 — Sales & invoicing

**Goal:** New sale, product sale, invoices, quotations, payments.

**Screens:** `ADM-05`, `ADM-06`, `ADM-07`, `ADM-08`.

**Prompt:**
> Build Sales. **New Sale stepper (`ADM-05`):** Customer → Type (Spares/Product/AMC) → Items (Product→Brand→Model or spares, qty, price from master) → AMC add-on (RO only) → Discount (enforce limits from settings: technician ≤5%, 5–10% creates an `approvals` row, >10% blocked) → Gift (auto-suggest + log when total ≥ threshold) → Payment (Cash/Transfer; Transfer requires txn_id + description ONLY — manual capture, NO payment gateway in staff billing). Running right-rail summary with subtotal/discount/GST/total. If both product + spares in cart, generate TWO invoices. **Product Sale (`ADM-06`):** guided flow ending in Warranty toggle (auto-create warranty + reminder) and Installation toggle (auto-create a `service_ticket` + auto-assign technician). **Invoice view (`ADM-07`):** GST-compliant invoice (with/without GST lines, HSN), print/PDF/Share-on-WhatsApp, payment status + link for dues. **Quotations (`ADM-08`):** create/convert/lost with reason; show Lead→Quotation→Sales ratio. Update inventory on sale; write to `invoices`, `invoice_items`, `warranties`, `service_tickets` as needed.

**DoD:** Can complete a sale end-to-end; two-bill rule works; discounts gated; invoice generates; inventory decrements; quotation converts.

---

### PHASE 6 — Service, scheduling, AMC/Warranty

**Goal:** Tickets, complaint capture, assignment, AMC lifecycle.

**Screens:** `ADM-09`, `ADM-10`, `ADM-11`, `ADM-12`, `ADM-13`.

**Prompt:**
> Build Service. **Tickets list (`ADM-09`):** table + kanban toggle, filters (status/priority/type/technician/date/area), live SLA countdown from `sla_due_at` with color status, repeat-complaint flag. **New Complaint (`ADM-10`):** Customer → Equipment (auto-shown if owned) → Name-of-complaint + Nature-of-complaint → Type auto-detected (paid/warranty/amc from warranties/amc_contracts; Paid not freely selectable, show reason + purchase/expiry) → Priority → Appointment (Always or Date&Time within work hours). **Appointments (`ADM-11`):** calendar + per-technician timeline; auto-assign engine using availability + location + priority + customer availability; enforce no two simultaneous appointments per customer and unlock next only after current completes; drag-to-reassign with conflict warnings. **AMC/Warranty list (`ADM-12`):** tabs, status chips (active/due-soon/expired), renewal highlights, Sell AMC. **AMC plan builder (`ADM-13`):** plan tiers, years→auto price (more years = lower per year), inclusions, gift, "service every 3 months"; on AMC sale auto-create the year's scheduled `appointments`. Remember: warranty/AMC visits cost ₹0 but still record spare quantity (inventory deducts, revenue doesn't).

**DoD:** Raise ticket with auto-detected type; auto-assign respects rules; AMC creates scheduled visits; SLA timers show.

---

### PHASE 7 — Technician App (offline-first)

**Goal:** Attendance, jobs, navigation, on-site service, ratings, sync.

**Screens:** `TECH-01`…`TECH-10`.

**Prompt:**
> Build the Technician App (technician group), offline-first via a Dexie queue in `src/lib/offline/` that syncs to Supabase on reconnect. **Attendance (`TECH-01`):** geo-fence check (Mark Attendance disabled unless inside office radius from settings), selfie capture, then Affirmation/Pledge/Meeting ticks; lock these after the late cutoff; write `attendance` with `is_late`. **Spare receipt (`TECH-02`):** allocated spares + signature pad (tech + admin), confirm received. **Home/Today (`TECH-03`):** route-ordered job cards (type badge, priority, appointment, call/WhatsApp, Start/Navigate), earnings ticker. **Map (`TECH-04`):** route to customer, distance-reach indicator (green on-time / red off-route via per-km time), "I've arrived" starts the productivity timer (auto via geofence if possible); stream location to `technician_locations`. **Job detail (`TECH-06`):** previous history timeline, coverage type, costing rule. **On-site stepper (`TECH-07`):** timer → before-image (geotag+timestamp watermark) → SOP checklist (each step has expected minutes; flag overruns) → after-image → spares used (search OR voice input) → charges (₹0 for warranty/AMC, discount capped at 5%) → RO checklist (TDS before/after, tank clean, product explained, client name) → create invoice → tech + customer signatures → payment (cash/transfer; transfer = manual txn-ID + description, NO gateway) → close (no OTP). Allow "Generate Enquiry" → create a `lead` referenced to this technician. **Rating (`TECH-08`):** customer stars; **4.5★–5★ → show Google review link**, below 4.5 → hide it and capture reason + notify operation admin. **History (`TECH-09`)** and **Profile (`TECH-10`)** with stats/incentive progress. Everything must queue and work offline.

**DoD:** Full job lifecycle works offline and syncs; geofence attendance enforced; tracking updates; invoice + signatures + payment complete on-device.

---

### PHASE 8 — Customer App

**Goal:** Self-service booking, enquiries, products, bookings.

**Screens:** `CUST-01`…`CUST-08`.

**Prompt:**
> Build the Customer App (customer group). **Home (`CUST-01`):** address bar (fill/confirm), four tiles (Service Booking, Spare Enquiry, Product Enquiry, AMC Enquiry), AMC/warranty status cards, "next service due" banner. **Service Booking (`CUST-02`):** chat-style stepper → Product/Model/Brand (auto-shown if owned, else add to a service enquiry), issue description (text + photo/voice), slot pick, coverage auto-detected (free if warranty/AMC), confirmation → creates `service_ticket`. **AMC (`CUST-03`):** show next service/coverage; enable booking only within the admin window; plan tiers + in-app online payment via gateway (the ONLY place a payment gateway is used). **Product Enquiry (`CUST-04`):** topic chips trigger the WhatsApp/AI flow (send matching video/link), "request quotation" creates a `lead`. **Spare Enquiry (`CUST-05`)**, **My Products (`CUST-06`)** with warranty/AMC + register-via-QR, **Bookings (`CUST-07`)** with live technician ETA tracking and invoice download, **Profile (`CUST-08`)** with multiple addresses + referral wallet. Build a `<LiveTracking>` component reusing Supabase Realtime on `technician_locations`.

**DoD:** Customer can book a service that appears in the admin queue; enquiries create leads; live tracking shows technician; AMC renewal works.

---

### PHASE 9 — Automation (WhatsApp, leads, PO)

**Goal:** Lead pipeline, WhatsApp/AI flows, auto purchase orders.

**Screens:** `ADM-22`, `ADM-23`, `ADM-20`, `ADM-21`.

**Prompt:**
> Build Automation. **Leads (`ADM-22`):** Kanban pipeline (New→Contacted→Quoted→Won/Lost) + table, source-wise conversion analytics, referral points (per-point value admin-set in settings, minimum 50, reflect as agreed — no fixed conversion). **WhatsApp/AI flow builder (`ADM-23`):** map triggers (enquiry_type: online/price/quality/customization/water_premium/budget) to actions (send video/quotation/link) from `automation_flows` + `video_library`; integrate WhatsApp Cloud API send; add an `/api/whatsapp/webhook` route to receive inbound messages and run the matching flow; office-hours + human-handoff fallback. **PO automation (`ADM-20`):** when `inventory.stock_qty ≤ min_stock`, draft a `purchase_order` to the cheapest/preferred supplier and send it via WhatsApp; manual create + approval over a value threshold (`approvals`). **Bill Entry (`ADM-21`):** form defaulting previous bill + supplier, OCR-upload optional, posts to inventory + expenses. Wire milestone WhatsApp notifications (booked, assigned, on-the-way, completed, invoice).

**DoD:** Inbound WhatsApp triggers a flow; low stock drafts/sends a PO; leads move through pipeline; notifications fire on milestones.

---

### PHASE 10 — HR, Payroll, Reports & system pages

**Goal:** Salary/incentives/rewards, reports/P&L, notifications, audit, new pages.

**Screens:** `ADM-24`…`ADM-31`, plus new pages `ADM-32`…`ADM-38`, `TECH-11`.

**Prompt:**
> Build the remaining admin modules. **HR:** Salary (`ADM-24`) auto-computed from attendance (late hours ×2 deduction), revenue component, and incentives; Incentive Master (`ADM-25`); Rewards (`ADM-26`) with thresholds (min 51 reviews, min ₹1,50,000 revenue) and a log of rewards given; bulk payslips. **Reports:** Sales & Service (`ADM-27`) with first-time-fix, repeat rate, avg per-call value, technician-wise; **P&L (`ADM-28`)** with With/Without-GST toggle and expense breakdown (marketing/stationery/salary/petrol), Excel export; **Performance scoreboard (`ADM-29`)** KRA/KPI leaderboard (operation admin 24h-resolution KPI; sales admin calls-ratio KPI). **Workspace (`ADM-31`):** to-do checklist that rolls unfinished tasks to next day, notifications/follow-ups/reminders, AI confirmation-call card before dispatch. **New pages:** Notifications Center (`ADM-32`), Approvals Queue (`ADM-33`), Complaints & Escalations (`ADM-34`), Campaign Manager (`ADM-35`), NPS/Feedback dashboard (`ADM-36`), Returns/Replacement (`ADM-37`), Audit Log viewer (`ADM-38`), and the technician Day-Sheet (`TECH-11`). Ensure every sensitive action writes to `audit_log` and raises a `notification` where relevant.

**DoD:** Payroll computes from real data; P&L and reports render with GST toggle; approvals route correctly; audit log searchable.

---

## 7. Cross-cutting conventions (apply in every phase)

- **Validation:** Zod schema per entity in `src/lib/validation/`; validate on server actions.
- **Mutations:** server actions only; never trust client; re-check RLS-relevant ownership.
- **Errors/loading/empty:** every list and form has all three states.
- **Audit:** wrap create/update/delete on sensitive tables to write `audit_log`.
- **Notifications:** important events insert into `notifications` (+ WhatsApp where set).
- **Money:** store integers in paise or numeric(12,2) consistently; one helper for currency.
- **Dates/time:** store UTC; display in IST.
- **i18n:** wrap UI strings for English/Tamil from the start (even if Tamil filled later).
- **Offline (technician):** all field actions go through the Dexie queue + sync layer.
- **Tests:** add a smoke test per module (happy path) before marking a phase done.

---

## 7a. Known issues from the design mockups — MUST be fixed in the real build

The `.dc.html` design mockups have some intentionally-static / unfinished interactions. These are **not acceptable in the coded app** — treat each as a hard requirement and verify in every phase's Definition of Done.

**1. Every toggle and button must actually work (no dead/static controls).**
In the mockups, several toggles and buttons are visual-only. In the build, **every** interactive control must be wired to real state or a server action:
- Tab/segment toggles (e.g. Products/Spares, AMC/Warranty, table↔kanban, dashboard Layout A/B) must switch the visible content and reflect the active state.
- Action buttons (Add, Edit, Save, Assign, Approve, Start, Navigate, Pay, Sell AMC, Generate PO, Export, View, "…" row menus) must perform their action, not just look clickable.
- Sidebar items and bottom-tab items must navigate to the correct route and set the correct active state.
- Disabled states must be intentional (e.g. AMC "Book" disabled until due window) — not accidental dead buttons.
- **DoD check (every phase):** click every button/toggle on the built screens; each one does something real or is intentionally disabled with a reason. No control is inert.

**2. The English/Tamil toggle must translate EVERYTHING (no leftover English).**
In the mockups, switching to Tamil (த) leaves some labels still in English. In the build, the language toggle must switch **100% of visible UI strings** — including ones easy to miss:
- All static labels, headings, section titles, button text, table headers, filter/sort labels, tab names, sidebar items, empty/loading/error messages, toasts, badges/status labels, placeholders, tooltips, and date/number formatting.
- Implement proper i18n (e.g. `next-intl` or `next-i18next`): **no hardcoded strings anywhere** — every visible string comes from a translation key with both `en` and `ta` values. A missing `ta` key must fall back visibly flagged in dev, not silently render English in prod.
- Dynamic/seeded data (names, areas) can stay as-is, but **all chrome/UI text must translate.**
- Persist the chosen language (per user) and default sensibly.
- **DoD check (every phase):** toggle to Tamil on each built screen and confirm **zero** English UI strings remain; toggle back to English and confirm the same. Add a quick script/lint to catch hardcoded JSX strings.

> Apply both checks retroactively to any screens already built, and to every new screen going forward.

---

## 8. First-run setup

```
1. npx create-next-app (handled in Phase 0)
2. Create a Supabase project; put keys in .env.local
3. supabase db push   # apply migrations (Phase 1)
4. npm run seed       # seed org, master user, sample data
5. npm run dev
6. Log in as the seeded master user -> /dashboard
```

---

## 9. Build order summary

`Phase 0 setup → 1 schema/RLS → 2 auth/shells → 3 customers → 4 masters/inventory → 5 sales → 6 service/AMC → 7 technician app → 8 customer app → 9 automation → 10 HR/reports/system`.

Each phase is shippable on its own. Stop after Phase 6 for a working back-office MVP; Phases 7–8 add the mobile apps; 9–10 add automation and analytics.

---

### One-line summary
A single Next.js 15 + Supabase codebase with three role-based experiences (Admin Web, Technician PWA, Customer PWA), built in 11 reviewable phases — paste each phase prompt into Claude Code, verify the Definition of Done, commit, and continue.
