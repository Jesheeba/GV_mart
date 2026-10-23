# GV Mart UI/UX Audit — Phase 1: Discovery

Repo root: `C:\Users\JESHEEBA\Desktop\GV_mart`
App root: `C:\Users\JESHEEBA\Desktop\GV_mart\gv-mart` (`src/` is the whole app)

> Note: a prior "full-app UI council audit" (9-persona review, ~330 findings) was completed 2026-08-01→08-02 across all 90+ screens. This audit re-examines the app from scratch; where findings overlap with that prior pass we'll note it as "previously addressed" vs. "regressed/new" in Phase 2.

## 1. Tech stack & architecture

**Framework / build tool**
- React 19.2.7, TypeScript 6.0.2, Vite 8.1.1 (`@vitejs/plugin-react` + `@tailwindcss/vite` + `vite-plugin-pwa`). Built as a PWA, also wrapped with Capacitor 8 for Android/iOS (`gv-mart/android`, `gv-mart/ios`, `capacitor.config.ts`).
- Pure client-side SPA — **no Next.js**. Routing via `react-router-dom` v7 data router (`createBrowserRouter`), not file-based.

**Routing**
- Single config: `src/router.tsx` (325 lines). Nested route objects, `React.lazy` per-page code splitting via a `lazyPage()` helper, three independent lazily-loaded "sub-apps" (Admin / Technician / Customer), each gated by role guards.
- Guards: `src/lib/guards.tsx` — `RequireAuth` (session check → `/login`) and `RequireRole` (role allow-list → `roleHomePath(role)`). Role list/home mapping: `src/lib/roles.ts`.
- Admin sidebar nav model is a **separate** file from router guards: `src/app/admin/nav.ts` (`ADMIN_NAV`, each item carries its own `roles` list) — a second hand-maintained source of truth for "who sees what" (see §6H).

**State management**
- No Redux/Zustand/MobX. Server state: `@tanstack/react-query` v5 (`src/lib/queryClient.ts`), ~30 domain hooks in `src/hooks/use*.ts` + matching `src/services/*.ts` calling Supabase.
- Global UI state via React Context: `AuthProvider`, `ThemeProvider` (`src/lib/theme/ThemeProvider.tsx`), `ToastProvider` (`src/components/ui/toast.tsx`), `I18nProvider`.
- Forms: `react-hook-form` + `@hookform/resolvers` + `zod` schemas under `src/lib/validation/*.ts` (one per domain).
- Backend: Supabase (RLS is the real access boundary; client-side role guards are explicitly "UX only" per code comments).
- Offline support (technician app only): Dexie (IndexedDB) + custom outbox/sync engine (`src/lib/offline/{db,capture,outbox,sync,geo}.ts`), started from `TechnicianShell`.

**Styling approach**
- Tailwind CSS v4, CSS-first config — **no `tailwind.config.js`**; tokens/theme live inside `src/index.css` via `@theme inline`.
- shadcn/ui scaffolding (`components.json`: style `"base-nova"`, baseColor `"neutral"`, icons `"lucide"`) but built on `@base-ui/react` as the headless primitive layer (not Radix).
- `class-variance-authority` (cva) for variants; `clsx` + `tailwind-merge` combined in `cn()` (`src/lib/utils.ts`).
- Internal design-system name found in code comments: **"Finexy"** — cream canvas, near-black "ink" primary, coral-orange accent, 20px card radius, pill-shaped buttons/nav.

**Theme / design tokens**
- `src/index.css` is the single source of truth: CSS variables (`--ink`, `--accent`, `--accent-soft`, `--bg`, `--surface`, `--surface-alt`, `--border`, `--text`, `--text-muted`, `--success`, `--warning`, `--danger`, `--info`, `--radius-card`, `--radius-subcard`) under `:root`, a `.dark` override block, and a `@theme inline` block mapping to Tailwind utilities.
- **Dark mode is technician-app-only by design** — `ThemeProvider` explicitly forces light mode outside `/technician/*` regardless of stored preference ("Admin and Customer are light-only... outdoor Technician App"). Toggle lives only in `TechnicianShell`'s overflow menu.
- No separate JSON token file — CSS vars only.

**Icons** — `lucide-react` throughout.

**Fonts**
- Primary: "Plus Jakarta Sans Variable" via `@fontsource-variable/plus-jakarta-sans` (self-hosted npm package, not a CDN link).
- Secondary: "Noto Sans Tamil" self-hosted woff2 (`public/fonts/NotoSansTamil-Regular.woff2`), `@font-face` with Tamil-only `unicode-range` — added because Plus Jakarta Sans has no Tamil glyphs and Capacitor's Android WebView can't be trusted to have a system Tamil font.
- Font stack: `"Plus Jakarta Sans Variable", "Plus Jakarta Sans", "Noto Sans Tamil", ui-sans-serif, system-ui, sans-serif`.
- i18n: i18next + react-i18next, two locales (`en`, `ta`) — `src/lib/i18n/{en,ta}.json`.

## 2. Full route/page list by role

Router: `src/router.tsx`. Roles (`src/lib/roles.ts`): `master | operation_admin | sales_admin | technician | customer`. `STAFF_ROLES = [master, operation_admin, sales_admin]`. In router.tsx: `SALES_ROLES=[master,sales_admin]`, `OPS_ROLES=[master,operation_admin]`, `MASTER_ONLY=[master]`.

### Public
| Path | Page |
|---|---|
| `/` | redirect → `/login` |
| `/login` | `LoginPage` |
| `*` | `NotFoundPage` |

### Admin area (`/admin/*`, inside `AdminShell`) — entry requires any STAFF_ROLES

**All staff**
- `/admin` (index) → `DashboardPage`
- `/admin/workspace`, `/admin/tasks`, `/admin/huddle`, `/admin/notifications` → Workspace / Tasks / Huddle / Notifications

**Sales roles (master, sales_admin)**
- `/admin/customers`, `/new`, `/:id`, `/:id/edit`
- `/admin/sales`, `/new`, `/invoices/:id`
- `/admin/quotations`, `/new`, `/:id`
- `/admin/my-day` (sales_admin's default landing page)
- `/admin/leads`, `/leads/:leadId`
- `/admin/automation`
- `/admin/rentals`
- `/admin/campaigns`

**Ops roles (master, operation_admin)**
- `/admin/service`, `/new`, `/appointments`, `/:id`
- `/admin/technicians`, `/map`, `/attendance`, `/spares`, `/:id`
- `/admin/inventory`
- `/admin/suppliers`
- `/admin/purchase`
- `/admin/complaints`
- `/admin/returns`

**Master only**
- `/admin/amc`, `/:id`
- `/admin/hr`
- `/admin/accounts`
- `/admin/reports`
- `/admin/masters` (25+ sub-tabs: Brands, Models, Products, Spares, Gifts, AMC Plans, Incentive Rules, Settings, SOP Steps, Water Quality, etc. — tabs, not separate routes)
- `/admin/approvals`
- `/admin/audit-log`

### Technician area (`/technician/*`, role: technician only, inside `TechnicianShell`)
- `/technician` (index) → `TechnicianHomePage`
- `/technician/map`, `/attendance`, `/history`, `/history/:visitId`, `/profile`
- `/technician/spares`, `/spares/history`
- `/technician/search`
- `/technician/jobs/:ticketId`, `/jobs/:ticketId/route`, `/jobs/:ticketId/rating`
- `/technician/day-sheet`, `/notifications`, `/tasks`, `/huddle`
- `/technician/jobs/:ticketId/visit` → `OnSiteVisitPage` — deliberately rendered **outside** `TechnicianShell` (own Suspense boundary, no bottom tab bar) so the full-screen job stepper doesn't compete with shell chrome mid-job.

### Customer area (`/customer/*`, role: customer only, inside `CustomerShell`)
- `/customer` (index) → `CustomerHomePage`
- `/customer/products`
- `/customer/bookings`, `/:id`
- `/customer/profile`
- `/customer/amc`, `/:productId`
- `/customer/book-service`
- `/customer/product-enquiry`, `/catalog/:productId`, `/callback`, `/compare`
- `/customer/spare-enquiry`
- `/customer/notifications`

## 3. Layouts (shared shells)

**`AdminShell`** (`src/app/admin/AdminShell.tsx`, 225 lines) — desktop-oriented.
- Left vertical icon-only rail (w-16, floating "card" panel) built from `ADMIN_NAV`, filtered by role; badge on "My Day" for lead-followup counts.
- Header: global search (`AdminGlobalSearch` — autocompletes customers + tickets), notification bell w/ unread badge, language toggle, user menu.
- Also mounts cross-cutting modals/banners regardless of current page: `CallReturnPrompt`, `PoApprovalPromptModal`, `PoReceiptPromptModal`, plus a background job-overrun watcher firing toasts.
- `<Outlet/>` inside the only scrollable `<main>`.

**`TechnicianShell`** (`src/app/technician/TechnicianShell.tsx`, 193 lines) — mobile-oriented, field use.
- Bottom tab bar (Home/Map/Attendance/History/Profile).
- Header: logo, offline-sync-status chip, notification bell, overflow menu (theme toggle + language — consolidated here because the header didn't fit a 360–412dp phone), user menu.
- Starts/stops offline sync engine on mount/unmount; streams live GPS for the whole session, shows an inline location-permission-error banner on failure.
- Deactivated technicians see a dedicated full-screen "deactivated" state instead of the shell (still authenticated, functionally locked out, with sign-out).
- Mounts `NewJobAssignedBanner`, `NewTaskAssignedBanner`, `ShiftEndPromptModal` shell-wide.
- Only shell supporting dark mode.

**`CustomerShell`** (`src/app/customer/CustomerShell.tsx`, 67 lines) — mobile-oriented, lightest.
- Bottom tab bar (Home/My Products/Bookings/Profile).
- Header: logo, notification bell, language toggle, user menu.
- Mounts `TechnicianAssignedBanner` and `OtpAlertBanner` shell-wide.

All three shells independently re-implement profile loading/error states, unread-count badge logic, and near-identical notification-bell JSX (candidate for consolidation — see §6I).

## 4. Shared/reusable component library

**Primitive layer** — `src/components/ui/` (shadcn-style, wraps `@base-ui/react`):
`button`, `input`, `label`, `card`, `badge`, `dialog`, `dropdown-menu`, `popover`, `tabs`, `table` (low-level), `calendar` + `date-picker`, `skeleton`, `map` (maplibre wrapper), `toast` + `toast-context`.

**Notable gap**: no dedicated `Select`/`Combobox` primitive — **62 files** use plain native `<select>` instead of a styled component. Flagging as a real consistency issue for Phase 2.

**Shared, higher-level components** — `src/components/shared/`:
`DataTable`, `EntityCrudTable` (composes DataTable — not a duplicate), `ColumnPicker`, `Autocomplete`, `AddressForm`/`AddressMapPicker`/`AddressPickerModal`, `BottomTabBar`, `ComingSoonPage`, `DraftBanner`, `ErrorBoundary`, `FullPageLoader`/`FullPageError`, `HandoverPrintSheet`/`TopCustomersPrintSheet`, `HighlightKpiCard`/`KpiCard` (two separate KPI tiles — see §6D), `LanguageToggle`/`PreferredLanguageSelect`/`VideoLanguageSelect` (three language pickers — see §6E), `MissingProductAlert`/`NotInInventoryProductDialog`, `ReorderableListCard`, `RouteFallback`, `SegButton` (code comment notes it was extracted from duplicated markup once, but not everywhere — see §6), `StatusDot`, `Stepper`, `UserMenu`.

## 5. Modals, drawers, dropdowns, toasts — usage inventory

**Dialogs/modals/sheets**, by flow:
- **Leads**: `AssignLeadDialog`, `BulkSetFollowupDialog`, `RescheduleDialog`, `SetFollowupDialog`, `LogOutcomeSheet`, `PostServiceCallSheet`
- **Customers**: `DeleteCustomerDialog`, `TdsSuggestionDialog`
- **HR**: `AddStaffDialog`
- **Huddle**: `IssueDialog`
- **Tasks**: `AssignTaskDialog`, `TaskDetailDialog`
- **Technicians**: `PasswordRevealDialog` (reveal a technician's login password)
- **Purchase**: `PoApprovalPromptModal`, `PoReceiptPromptModal` (shell-wide, fire regardless of current page)
- **Sales**: `RecordPaymentDialog`
- **Cross-cutting**: `AddressPickerModal`, `NotInInventoryProductDialog`
- **Technician app**: `ShiftEndPromptModal` (shell-wide)
- **Customer app**: `TrackingSheet` (bottom-sheet live tracking)

**Dropdowns**: `TechnicianShell` header overflow menu, `UserMenu` (all 3 shells), ~15+ admin list-row action menus.

**Toasts**: used extensively for async feedback across nearly every CRUD page. Notable shell-wide ones: `AdminShell`'s app-wide job-overrun alert, `CallReturnPrompt`'s "customer asked you to call back" reminder.

**Bottom sheets/full-screen steppers**: `OnSiteVisitPage` (technician job-completion stepper, routed outside the shell to act like a full-screen takeover); `LogOutcomeSheet`, `PostServiceCallSheet`, `TrackingSheet` all use "Sheet" naming but there's **no shared `Sheet` primitive** — each hand-built (see §6F).

## 6. Duplicate / near-duplicate components & utilities

**A. Status badges** — six separate per-domain components (`FollowupBadges`, `LeadBadges`, `QuotationBadges`, `SalesBadges`, `TicketBadges`, `JobBadges`) each hand-code their own status→variant/label switch on top of the one generic `Badge` primitive, instead of one lookup-table-driven component. Plus a separate `StatusDot` component and standalone lib helpers (`booking-status.ts`, `amc-status.ts`, `attendance-status.ts`) — three different "status color" conventions coexisting.

**B. Currency formatting duplicated 3x+** — canonical `formatCurrency()` in `src/lib/sale-calc.ts:13`, but re-implemented locally with *different rounding behavior* in `CustomerBookingDetailPage.tsx:32` and `AmcBookingPanel.tsx:10`, plus dozens of inline `₹${n.toLocaleString("en-IN")}` one-offs (`AmcWarrantyListPage.tsx:54`, `IncentivesTab.tsx:21`, `PurchaseOrdersTab.tsx:55`, `BillEntryTab.tsx:83-84`, `PoApprovalPromptModal.tsx:169-180`).

**C. No shared date-display formatter** — `src/lib/ist.ts` only covers IST business-rule logic, not display. 47 files independently call `.toLocaleDateString(...)` with inconsistent args — some `"en-IN"`, some no locale at all (device-locale fallback), some different explicit option objects (`CustomerDetailPage.tsx:48` vs. `CustomersListPage.tsx:55` use different year formats; `CustomerAmcProductDetailPage.tsx:30` and `CustomerHomePage.tsx:91-92` call bare `.toLocaleDateString()`).

**D. Three KPI tile patterns** — `KpiCard`, `HighlightKpiCard`, and a third page-specific one (`KpiTileStrip` + `kpiTilesView.ts`).

**E. Three language-selector components** — `LanguageToggle`, `PreferredLanguageSelect`, `VideoLanguageSelect`.

**F. Three ad hoc "Sheet" implementations**, no shared primitive (see §5).

**G. No shared `Select`** — 62 files use native `<select>` (see §4) — real visual-consistency gap across browsers/OS.

**H. Two parallel role-visibility sources** — router's `RequireRole` arrays vs. `ADMIN_NAV`'s per-item `roles` field. Consistent today by inspection, nothing enforces they stay that way.

**I. Shell header duplication** — all three shells hand-roll near-identical notification-bell JSX/badge styling instead of a shared `<NotificationBell/>`.

(`EntityCrudTable` vs `DataTable` checked and confirmed to be legitimate composition, not a duplicate.)

## 7. Main user journeys per role

**Master** (owner/super-admin)
1. Login → Dashboard → KPI tiles / huddle issues → Reports (P&L, sales/service, coverage, top customers).
2. Masters configuration: Brands/Models/Products/Spares/Gifts/AMC Plans/Incentive Rules/Settings/SOP Steps/Water Quality — foundational data for every other role.
3. Lead-to-sale pipeline oversight: My Day/Leads Kanban → assign/follow-up/log outcome → Quotation → New Sale → Invoice.
4. Service oversight: tickets list/Kanban → assign technician → Technicians Map/Attendance → approve AMC/Warranty.
5. Operations/finance: Purchase (quotes→PO→approval→bill entry/receipt) → Accounts → HR (salary/incentives/rewards) → Approvals → Audit Log.
6. Cross-cutting: Automation (WhatsApp templates/flows) and Campaigns.

**Operation Admin**
1. Login → Dashboard → job-overrun alerts / live technician map.
2. Service lifecycle: tickets list → New Complaint → assign/reschedule Appointments → Ticket Detail (SLA) → resolve.
3. Technician management: list → attendance → spare handover/return → technician detail (documents, tiers).
4. Inventory/procurement: Inventory → Suppliers → Purchase.
5. Complaints/Returns.
6. Shared staff tasks: Tasks/Huddle/Workspace/Notifications.

**Sales Admin**
1. Login → lands directly on **My Day** (not Dashboard) → overdue/today follow-ups queue.
2. Lead management: Leads Kanban → New Lead → assign/reschedule/log outcome → Lead Detail timeline.
3. Customer & sale flow: Customers → Customer Detail/Form → New Sale (items→summary→payment) → Invoice.
4. Quotations: list → new → detail → follow up to convert.
5. Supplementary: Rentals, Automation/Campaigns, Workspace/Tasks/Huddle/Notifications.

**Technician**
1. Login → Home (today's jobs) → Day Sheet/Map for routing.
2. Attend a job: Job Detail → Job Route → On-Site Visit full-screen stepper (install/spare select, Sell AMC) → photos/signature/voice note → Completion OTP → mark complete.
3. Spare parts: Spare Handover → History.
4. Attendance & shift: clock in/out → Shift-End Prompt at day's end.
5. History & feedback: History list → Detail → Rating Page.
6. Supplementary: Search, Tasks, Huddle, Notifications, Profile.

**Customer**
1. Login/self-service → Home (owned-product status, next-service-due banner).
2. Service booking: Book Service → OTP/Technician-assigned banner → live Tracking Sheet/Map → Completion.
3. Product research/purchase intent: Product Enquiry (catalog, detail w/ photo hero, video library) → Compare → Callback/Quotation CTA → Request Callback.
4. Warranty/AMC: My AMC list → Product Detail → AmcBookingPanel (renew/buy).
5. Account management: Bookings list → Detail; Profile (language, addresses).
6. Spare Enquiry (self-service).

---

*Method note: full structural scan of router.tsx, guards.tsx, roles.ts, nav.ts, all three shells, index.css, components.json, package.json, vite.config.ts, main.tsx; every file under src/app, src/components/ui, src/components/shared, src/hooks, src/services, src/lib enumerated by path; targeted greps covered every Dialog/Modal/Drawer/Sheet/toast usage, every native `<select>` usage, every date/currency formatting call site, and every *Badge* component.*
