# GV Mart — Vite Implementation Plan (Claude Code)

A Vite-adapted version of the build spec. The **Supabase backend is identical** to the Next.js plan — same data model (Section 5 of `GV_Mart_ClaudeCode_BuildSpec.md`), same RLS, same five role logins, same Finexy design. **Only the frontend framework and the home for server-only code change.**

> Companion files: `GV_Mart_ClaudeCode_BuildSpec.md` (data model in Section 5 — reuse as-is), `GV_Mart_ClaudeDesign_Workflow_Complete.md` (Finexy design + screen IDs), the `.dc.html` mockups (visual reference).

---

## ⚠️ AUTHORITY & v2.2 VALUE OVERRIDES (read first — these win over everything below)

**The client-signed `GVMart-Requirement-Confirmation v2.2.pdf` is the source of truth.** Where any value/rule here conflicts, use v2.2:

| Topic | ✅ v2.2 value |
|---|---|
| Inventory | **min stock 10, reorder qty 10** (seed 10/10) |
| Travel time | **1 km = 5 min** (`per_km_minutes = 5`) |
| Geofence | **"inside office only"** — no distance figure shown |
| Salary | **revenue-based, admin-set, NO fixed ₹** (configurable master) |
| Incentive rates | **admin-set in master**, no hardcoded % or ₹ |
| Customer review link | **only at 4.5★ or 5★**; technician incentive per review, admin-set |
| Lunch | **30 min; red over 45 min** |
| Referral points | **per-point value admin-set, min 50, "as agreed"** — no fixed conversion |
| Payments | **staff billing = manual txn-ID + description only (NO gateway)**; real gateway **only in Customer App** for AMC/online pay |
| Attendance | **Affirmation → Pledge → Meeting**, locked after **09:15** (admin-editable) |

**Do NOT build (not in signed v2.2):** SOP-time / complaint-name / zone masters, vendor price-history, GST-filing checklist, bank-payment-tracking screen, availability-exception windows, first-dispatch 10–50 ft trigger, OTP-to-close, selfie-attendance, fixed salary/incentive/referral numbers. Beyond v2.2 = change request.

**Build order = v2.2 stages:** (1) core sales/billing/service/inventory → (2) technician app + tracking + call tracking → (3) AMC/Warranty + customer app → (4) salary/incentives/rewards → (5) WhatsApp automation + auto-POs + reports.

---

## 0. What changes from the Next.js spec (read first)

| Topic | Next.js (old) | **Vite (this plan)** |
|---|---|---|
| Framework | Next.js 15 App Router | **Vite + React 18 + TypeScript** (SPA) |
| Routing | file-based `app/` | **React Router v6** (`createBrowserRouter`) with role-guarded routes |
| Data fetching | Server Components | **TanStack Query** (client) over a typed `services/` layer |
| Mutations | Server actions | **Supabase client calls** in `services/` (+ TanStack `useMutation`); trusted logic via **RPC / Edge Functions** |
| Server routes / webhooks / secrets | `/api` routes | **Supabase Edge Functions** (Deno) |
| Role enforcement | middleware + RLS | **route guards + RLS** (RLS is the real boundary) |
| Env vars | `NEXT_PUBLIC_…` | **`VITE_…`** (and server-only secrets live ONLY in Edge Function secrets) |
| PWA | next-pwa | **vite-plugin-pwa** |
| UI kit | shadcn/ui | shadcn/ui (Vite setup) + Tailwind |

**Unchanged:** Supabase Postgres + RLS + Auth + Storage + Realtime, the full Section-5 schema, the five separate role logins (no switcher), the offline Dexie queue for the Technician app, and the Finexy design system.

**Security rule (critical for Vite):** there is no trusted server in the browser. **RLS is your security boundary.** The `service_role` key must NEVER appear in the Vite client — it lives only in Edge Function secrets. Any logic that must be trusted (auto-PO to cheapest supplier, payroll math, approvals, payment confirmation, WhatsApp webhook) runs in **Postgres RPC functions or Edge Functions**, never in client code.

---

## 1. Stack & architecture

- **Vite + React 18 + TypeScript**, single app, three **role-routed shells**: `/admin/*`, `/technician/*`, `/customer/*`, plus `/login`.
- **React Router v6** with a `requireRole()` guard per route group.
- **TanStack Query** for all reads/writes; a `services/` layer wraps `supabase-js` so components never call Supabase directly.
- **Supabase** for DB/Auth/Storage/Realtime; **Edge Functions** for trusted/server-only logic.
- **Tailwind + shadcn/ui** styled to the Finexy tokens.
- **vite-plugin-pwa** for installable PWAs; **Dexie** offline queue for the Technician app.
- Wrap with **Capacitor** later if you need Play Store builds (same pattern as TNPSC Mentor).

---

## 2. Roles & separate logins (same as build spec Section 3)

Five distinct logins, **no role switcher**. On sign-in, read `role` from `profiles` and route:
- `master` → `/admin` (full)
- `operation_admin` → `/admin` (Operations dashboard + Service/Scheduling/Technicians/Workspace; gated out of masters/payroll/P&L/sales pricing)
- `sales_admin` → `/admin` (Sales dashboard + Sales/Quotations/Leads/Customers; gated out of service ops/payroll/masters/P&L)
- `technician` → `/technician`
- `customer` → `/customer`

Gate every route AND every sidebar item by role. **RLS enforces it for real** — route guards are just UX.

---

## 3. Folder structure (Vite)

```
src/
  main.tsx                 # router + providers (QueryClient, Auth, Theme, i18n)
  router.tsx               # createBrowserRouter + role guards
  app/
    admin/                 # admin shell + pages (dashboard, customers, sales, service, amc,
                           # technicians, inventory, suppliers, automation, hr, reports, masters, workspace)
    technician/            # technician shell + pages (home, map, attendance, history, profile, job/:id)
    customer/              # customer shell + pages (home, products, bookings, profile, book, enquiry)
    auth/                  # login, register
  components/
    ui/                    # shadcn primitives
    shared/                # DataTable, KpiCard, HighlightKpiCard, Stepper, StatusDot,
                           # SignaturePad, ImageUploader, MapView, VoiceInput, Autocomplete...
  services/                # supabase calls per domain: customers.ts, sales.ts, service.ts,
                           # inventory.ts, suppliers.ts, amc.ts, technicians.ts, hr.ts, reports.ts
  hooks/                   # useAuth, useRole, query hooks (useCustomers, useTickets...)
  lib/
    supabase.ts            # browser client (anon key only)
    queryClient.ts
    i18n/                  # en.json, ta.json + provider
    offline/               # dexie db + sync (technician)
    guards.tsx             # requireAuth / requireRole
  types/
    database.ts            # generated Supabase types
supabase/
  migrations/              # SQL (identical to Section 5 of the build spec)
  functions/               # Edge Functions (Deno): whatsapp-webhook, auto-po, payroll, approvals...
  seed/
```

---

## 4. Data layer pattern (no server actions)

- **Reads:** `services/<domain>.ts` exports typed functions calling `supabase.from(...).select(...)`; wrap in TanStack Query hooks (`useCustomers`, `useTicket(id)`).
- **Writes:** `services` functions call `supabase.from(...).insert/update/delete`, validated with **Zod** before the call; expose via `useMutation` with optimistic updates + invalidation.
- **Trusted writes** (money, payroll, auto-PO, approvals, payment confirm): call a **Postgres RPC** (`supabase.rpc('approve_discount', …)`) or an **Edge Function**, so the rule runs server-side under RLS, not in the browser.
- **Realtime** (live tracking, ticket status): Supabase Realtime subscriptions in a hook.

---

## 5. Trusted/server logic → Edge Functions + RPC

Put these server-side (Deno Edge Functions or SQL RPC), never in client code:
- `whatsapp-webhook` — receive inbound WhatsApp, run the matching automation flow.
- `send-whatsapp` — outbound notifications/templates (holds the WhatsApp token).
- `auto-po` — on low stock, draft + send PO to cheapest supplier.
- `compute-payroll` — salary = base + revenue component − late deduction + incentives.
- `approve-discount` / `approvals` — enforce ≤5% tech, 5–10% admin, >10% blocked.
- `confirm-payment` — verify/record transfer + reconcile.
Keep secrets (service_role, WhatsApp token, Maps server key) in **Edge Function secrets** only.

---

## 6. Database schema

Identical to **Section 5 of `GV_Mart_ClaudeCode_BuildSpec.md`** (all ~50 tables, `org_id`, RLS). Reuse it verbatim — Vite changes nothing about the database.

---

## 7. Phased build prompts for Claude Code (Vite)

Paste Sections 0–6 once for context, then one phase at a time. **Session rule to paste each time:**
> Context: GV Mart on **Vite + React 18 + TypeScript + Supabase**. Read the Vite implementation plan + `GV_Mart_ClaudeCode_BuildSpec.md` Section 5 (schema) + the Finexy design system before coding. No Next.js, no server actions, no `/api` routes — use a `services/` layer + TanStack Query, and Supabase Edge Functions/RPC for trusted logic. Audit existing files first. TypeScript everywhere, Zod validation, RLS on every table. Every control must be functionally wired (no static UI); the EN/த toggle must translate 100% of UI strings. Match Finexy (ink `#1A1A1A`, accent `#F5612C`, cream `#F4F1EC`, 20px cards, pill nav/buttons, colored-dot tables).

### PHASE 0 — Vite project setup
> Scaffold a **Vite + React + TypeScript** app. Add Tailwind and set up shadcn/ui (Vite method). Install `@supabase/supabase-js`, `@tanstack/react-query`, `react-router-dom`, `react-hook-form`, `zod`, `vite-plugin-pwa`, `dexie`, and an i18n lib (`react-i18next`). Create `src/lib/supabase.ts` (browser client, **anon key only**), `queryClient.ts`, the i18n provider with `en.json`/`ta.json`, and a Theme provider. Set up `router.tsx` with `createBrowserRouter` and empty route groups `/login`, `/admin/*`, `/technician/*`, `/customer/*`. Apply the Finexy design tokens as CSS variables + Tailwind theme; set Plus Jakarta Sans. Build base shared components: Button (ink/outline/accent pills), Card (20px), StatusDot, KpiCard, HighlightKpiCard (coral), DataTable skeleton. Add `.env.example` with `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (note: service_role goes ONLY in Edge Function secrets, never here). Configure PWA. Print run instructions.
> **DoD:** `npm run dev` runs; routes resolve; Supabase client imports; Finexy tokens + base components render; PWA installable.

### PHASE 1 — Database schema, RLS, seed (Supabase)
> Using Section 5 of the build spec, generate Supabase SQL migrations under `supabase/migrations/` for every table (types, FKs, indexes, `org_id`, timestamps, 5-member check on `customer_members`). Enable RLS on all tables with policies per the role model (Section 2): staff scoped by `org_id` and gated per module by role; technician limited to assigned rows; customer to own `customer_id`. Seed the `settings` row with defaults. Write a seed script: 1 org (GV Mart + GST), one login per role (master, operation_admin, sales_admin, technician, customer) with known test credentials, realistic Indian data (Voltas/Bluestar AC, Exide/Amaron/Luminous, RO/water brands, ~15 products with ₹ prices, ~20 spares with stock + min/reorder, 2 suppliers linked to items, ~25 Chennai-area customers with Tamil names + PINs). Generate TS types into `src/types/database.ts`. Verify migrations apply.
> **DoD:** tables + RLS live; one test login per role; types generated; seed runs.

### PHASE 2 — Auth + role-routed shells (separate logins, NO switcher)
> Build Supabase Auth login/register in `src/app/auth/`. On sign-in read `role` from `profiles` and route: master/operation_admin/sales_admin → `/admin`, technician → `/technician`, customer → `/customer`. Implement `requireAuth`/`requireRole` guards in `lib/guards.tsx` used by the router. **Separate role-based logins — no Owner/Operations/Sales toggle anywhere.** Gate the landing dashboard and every sidebar item by role (master = all; operation_admin = Operations dashboard + Service/Scheduling/Technicians/Workspace; sales_admin = Sales dashboard + Sales/Quotations/Leads/Customers). Build the Finexy **Admin shell** (floating icon sidebar filtered by role + top bar with global search, notifications, user chip, EN/த toggle — no switcher), and placeholder **Technician** (bottom tabs Home/Map/Attendance/History/Profile) and **Customer** (Home/My Products/Bookings/Profile) shells. RLS is the real enforcement; guards are UX.
> **DoD:** each role logs in to a *different* dashboard/sidebar; a sales_admin cannot reach Owner/Operations via any URL; no switcher exists; protected routes redirect.

### PHASE 3 — Customers module
> Build Customers in `/admin` using TanStack Query + a `services/customers.ts` layer (no server actions). **List (ADM-02):** Finexy DataTable with autocomplete search (mobile/name), filters (address type, area/PIN, has-AMC/warranty), status-dot column, pagination. **Detail (ADM-03):** profile header (address + map thumb via stubbed geocoding for now), family-members panel (max 5, set-primary, add/remove), tabs (Products / Service history timeline / Invoices / Leads), action buttons. **Add/Edit stepper (ADM-04):** Step 1 People (Name+Mobile pairs, "+" up to 5, Profession), Step 2 Address (Door/Flat/Street/Area/PIN/Landmark with autocomplete vs existing rows, type+ownership, auto district/state stub, map pin). Zod validation; `useMutation` with invalidation; live duplicate-mobile detection. **Every button/toggle must work**; Tamil toggle translates all labels.
> **DoD:** create/search/view/edit customers; members capped at 5; duplicates flagged; autocomplete works; all controls functional in EN and த.

### PHASE 4 — Masters, catalog & inventory
> Build Masters + Inventory + Suppliers via `services/`. **Masters (ADM-30):** CRUD for brands/models/products(price)/spares/gifts, AMC plans, warranty/incentive defaults, and `settings` (per-km time, geofence radius, work hours, late cutoff, discount limits, AMC window, referral point value); each change writes `audit_log` (via RPC). **Inventory (ADM-18):** Products/Spares tabs with stock, min-stock, reorder-qty, status dot (In/Low/Out), inline edit → `inventory_movements`. **Suppliers (ADM-19):** CRUD + link supplier→items with price, mark cheapest/preferred. All filters/toggles wired; bilingual.
> **DoD:** manage all masters; inventory shows correct status colors; suppliers linked; audit log records changes.

### PHASES 5–10 — Vite deltas (same screens, build later)
Build exactly the modules from build-spec Phases 5–10 (Sales, Service/AMC, Technician App, Customer App, Automation, HR/Reports/system pages) with these adaptations:
- Replace every "server action" with a `services/` function + TanStack `useMutation`.
- Trusted logic → **Edge Functions / RPC**: payment confirm + UPI (Phase 5), auto-assign + SLA (Phase 6), payroll + approvals (Phase 10), WhatsApp webhook + auto-PO (Phase 9).
- Realtime (live tracking, ticket status, technician location) → Supabase Realtime hooks.
- Technician app offline → **Dexie queue + sync** for attendance, photos, invoices.
- Keep the Phase 5–10 prompts from the build spec; just prepend "Vite/services-layer, no server actions" to each.

---

## 8. Conventions (apply every phase)

- **Services layer:** components never call Supabase directly — always via `services/` + query hooks.
- **Validation:** Zod per entity before any write.
- **Trusted logic:** money/payroll/approvals/auto-PO/webhooks live in RPC/Edge Functions, not the client.
- **Security:** RLS on every table is the real boundary; never ship the service_role key to the client.
- **No static UI** (build-spec §7a): every button, dropdown ("This Month"), toggle, popup, stepper, and row action is wired with active/loading/empty/error states.
- **Full i18n** (build-spec §7a): EN/த toggle translates 100% of UI strings; no hardcoded JSX text; persist choice.
- **Money** numeric(12,2) or paise; **dates** UTC stored, IST shown.
- **Offline** (technician) via Dexie queue.
- **Tests:** one smoke test per module before "done".

---

## 9. First-run setup

```
1. npm create vite@latest gv-mart -- --template react-ts   # (Phase 0 handles full setup)
2. Create a Supabase project; put VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY in .env.local
3. supabase db push            # apply migrations (Phase 1)
4. supabase functions deploy   # (later, when Edge Functions exist)
5. npm run seed                # org + one login per role + Indian sample data
6. npm run dev                 # log in per role to verify gated dashboards
```

---

## 10. Build order (matches your 4-day plan)

`Phase 0 setup → 1 schema/RLS/seed → 2 auth/role-shells → 3 customers → 4 masters/inventory` = the 4-day Foundation. Then `5 sales → 6 service/AMC → 7 technician → 8 customer → 9 automation → 10 hr/reports`.

> Your `GV_Mart_Phase1_4Day_Plan.md` still applies — just use these **Vite** phase prompts in place of the Next.js ones for Modules 0–4.

---

### One-line summary
Same Supabase backend, same roles, same Finexy design — rebuilt as a **Vite + React + TypeScript SPA** with React Router, a TanStack-Query `services/` data layer, and Supabase **Edge Functions/RPC** for the trusted server-side logic.
