# GV Mart UI/UX Audit — Phase 2: Full Audit Report

Findings are written up wave by wave as Phase 2 proceeds (per 2026-10-23 instructions), so nothing is lost if the session resets. Each finding has an ID, category (A–K per the brief), role, page, width, screenshot reference, description, severity, and suggested fix. Findings traced to the common AI-generated-app failure patterns in the brief are tagged **`vibe-code`**.

Severity scale: **Critical** (broken/blocking/data-loss) · **High** (clearly wrong, visible every time, affects a core flow) · **Medium** (real but narrower impact) · **Low** (polish).

Method note: captured with Playwright (scripts in `ui-audit/scripts/`) — full-page screenshots, `@axe-core/playwright` scans, and console-error capture on every page. Screenshots live in `ui-audit/screenshots/before/<area>/<width>/`. **Known artifact**: on mobile-shell pages taller than the viewport, the fixed bottom tab bar can appear "floating" mid-page in a *full-page* screenshot — this is a Playwright full-page-stitching artifact, not a real bug (verified against real scrolled-viewport captures on the Map page). Findings below were cross-checked against real viewport screenshots where this mattered.

---

## Wave 1 — Technician area

Role: `technician`. Widths: 375 (primary), 768 (primary), 1440 (quick check). Pages covered: Home, Map, Attendance, History (+ detail), Profile, Spares (+ history), Search, Day Sheet, Notifications, Tasks, Huddle, Job Detail, On-Site Visit stepper (step 1 only — an open visit already existed for the test technician's one seeded job, so "Start Visit" was reachable without triggering the data-writing "confirm arrival" action). Rating page and visit-submission/OTP were **not** reached, per instructions — scope stops the step before submit.

**Regression check against the Aug 2026 audit's Technician-phase (Phase 4) decisions**: dark-mode toggle present and working in the overflow menu — not regressed. Offline sync "Synced" status chip renders in the header — not regressed. SignaturePad's typed-name fallback was not reached this wave (visit stepper only opened to step 1) — no evidence either way, not re-litigated. Back-button placement (a known Minor backlog item) was consistent on the two screens that have one (Job Detail, Day Sheet) — full consistency sweep deferred to Phase 6.

### Findings

**TECH-001 — Quick-action labels overlap at mobile width** · Category **E** (Responsiveness) · `vibe-code` · role: technician · page: Home (`/technician`) · width: 375px · [`01-home.png`](screenshots/before/technician/375/01-home.png)
The "Spare receipt" and "Search customers" quick-action tile labels visually overlap each other, making both unreadable ("Spare rece" bleeds into "...arch customers"). Confirmed with a direct (non-stitched) viewport screenshot — not a capture artifact. Does not reproduce at 768px/1440px.
**Severity: High.** Fix: give the 4-across quick-action row a minimum tile width with text wrapping, or move to a 2-column grid / horizontal scroll below a breakpoint.

**TECH-002 — Notifications expose raw ticket UUIDs to the technician** · Category **I** (Content/microcopy) · `vibe-code` (leftover technical value shown to user) · role: technician · page: Notifications · width: all · [`10-notifications.png`](screenshots/before/technician/375/10-notifications.png)
Every "New job assigned" notification body reads literally "Ticket 383a62ef-d64b-4f11-9676-59a169bae9ee assigned to you." — a raw internal UUID, not a customer name or short reference.
**Severity: High** (every job-assignment notification, for every technician, indefinitely). Fix: template the notification body with the customer name/product instead of the raw ticket id.

**TECH-003 — Inconsistent date format on Daily Huddle** · Category **I** (Content) · `vibe-code` · role: technician · page: Daily Huddle · width: 375px · [`12-huddle.png`](screenshots/before/technician/375/12-huddle.png)
"Open problems"/"Recent meetings" show raw ISO dates ("2026-10-09") while every other technician screen (History, Job Detail) formats dates as "23 Oct 2026".
**Severity: Low.** Fix: route through the same date-display formatting used elsewhere (ties into the shared date-formatter gap already flagged in Discovery §6C).

**TECH-004 — No max-width on content at desktop widths** · Category **A** (Layout) · role: technician · width: 1440px · [`01-home.png`](screenshots/before/technician/1440/01-home.png)
Main content (cards, stats) stretches edge-to-edge across the full 1440px viewport, while the bottom tab bar stays centered in its own ~448px column (by design, per `BottomTabBar.tsx`) — the two don't line up, which looks unintentional on a wide window.
**Severity: Low** (technician app is mobile-first by design; this is an edge case). Fix: cap the scrollable content container at the same max-width as the tab bar, or treat wide viewports as explicitly out of scope and say so.

**TECH-005 — Stat tiles don't reflow at tablet width** · Category **A** (Layout/whitespace) · role: technician · width: 768px · [`01-home.png`](screenshots/before/technician/768/01-home.png)
The 2-column stat grid (Today's Jobs/Pending/Completed/Cancelled/Overdue) stays 2-up and just stretches wider, leaving large empty padding inside each tile instead of using the extra width (e.g. 3- or 5-across).
**Severity: Low.**

**TECH-006 — On-Site Visit stepper: one blank-page capture at 768px** · Category **K** (Perceived performance) · role: technician · page: On-Site Visit stepper · width: 768px · [`16-onsite-visit-step1.png`](screenshots/before/technician/768/16-onsite-visit-step1.png)
One automated capture rendered this page fully blank/white immediately after navigating to `/technician/jobs/:id/visit`, even though the DOM had real text content (confirmed via `innerText`). Did **not** reproduce on two manual repeat checks (same navigation path, same width) — looks like a transient paint flake rather than a deterministic bug.
**Severity: Medium**, flagged for monitoring rather than confirmed: this route is used outdoors over patchy connections, so if there's a real intermittent blank-paint window on load, a loading skeleton would mask it either way. Suggested: add an explicit loading skeleton for this route's initial mount.

**TECH-007 — Danger-colored text fails contrast app-wide** · Category **J** (Accessibility) · role: technician · ALL pages, ALL widths
`axe-core` flags `color-contrast` (serious) on `.text-danger` elements (the location-permission banner, "Very late"/overdue/overrun labels) on **every single technician page audited** — systemic, not page-specific.
**Severity: High** (systemic). Fix at the design-token level in Phase 3 (darken `--danger` or its paired background).

**TECH-008 — Icon button missing accessible name app-wide** · Category **J** (Accessibility) · role: technician · ALL pages
`label-content-name-mismatch` (serious) on a `.relative`-classed icon button in the header, present on every page — likely the notification bell or overflow-menu trigger.
**Severity: Medium** (systemic, screen-reader users can't tell what the control does).

**TECH-009 — Page content not wrapped in a landmark region** · Category **J** (Accessibility) · role: technician · ALL pages
`region` (moderate) on every page — content sits outside any landmark (`main`, `nav`, etc.).
**Severity: Low/Medium, systemic** — fix once at the shell/layout-template level in Phase 3 rather than per-page.

**TECH-010 — Heading level skip on Daily Huddle** · Category **J** (Accessibility) · role: technician · page: Daily Huddle
`heading-order` (moderate) — an `h3` appears without an intervening `h2`.
**Severity: Low.**

**TECH-011 — On-Site Visit stepper has the most accessibility gaps of any technician screen** · Category **J** (Accessibility) · role: technician · page: On-Site Visit stepper
`landmark-one-main` (moderate, no `<main>`), and on mobile, `label-content-name-mismatch` (serious) on the step-nav buttons (Spares/Activities/Charges icons don't expose their visible step name as the accessible name).
**Severity: Medium** — this is the most complex, highest-stakes screen in the technician app (job completion, signatures, payment) and currently has the weakest a11y coverage of any screen audited this wave.

### What's clean (worth recording, not just defects)
- Zero console errors / page errors on any technician page at any width.
- No `window.alert()`/`confirm()` usage, no clickable-`<div>` patterns found in `src/app/technician/**`.
- Empty states (Spares — "No handover for today yet", Tasks — "No tasks here", Profile — "No ratings yet"/"No referrals yet") all have an icon, a clear message, and are not blank tables — a genuinely good pattern, no vibe-code violation here.
- Overflow menu (theme + language) and user menu (profile + sign-out) both open/close cleanly with no z-index or clipping issues at any width tested.
- The "Assign Task" button visible to technicians on the Tasks page is **intentional** (documented in code: Phase 0's "fully-open hierarchy" decision lets any technician assign any org task) — not a permissions bug, not flagged.

---

## Wave 2 — Customer area

Role: `customer`. Widths: 375 (primary), 768 (primary), 1440 (quick check). Pages covered: Home, My Products, Bookings (+ detail), Profile, AMC, Book Service (step 1 only, not submitted), Product Enquiry catalog (+ callback, compare), Spare Enquiry, Notifications.

**Blocker hit and resolved before this wave could run**: `customer@gvmart.test` came back `user_banned` from Supabase Auth on first attempt. Investigated — not caused by anything in this session or explained by any prior memory (the 2026-10-05 mock-data-wipe work explicitly planned to *keep* this account; it was never executed anyway). Per the user's explicit instruction, unbanned the account and (after the shared test password also turned out not to match it — a separate, unrelated issue) reset its password to the standard `GvMart@2026` via the Supabase Admin API, both scoped to this one test auth user only. Flagging here for visibility since it's a real auth-side anomaly outside this audit's normal scope, not a UI finding — worth the user independently checking *why* that account got banned, in case it recurs.

**Regression check against the Aug 2026 audit's Customer-phase (Phase 5) decisions**: the booking-detail "About pricing" transparency copy (that phase's fix for a missing-i18n-key bug) renders correctly, in real English text, not a raw key — not regressed. Customer notification copy is human-readable — consistent with that phase's "Trust & Conversion" lens.

### Findings

**CUST-001 — Duplicate notification bell on the Home page** · Category **C** (Components) · `vibe-code` (same control built two different ways) · role: customer · page: Home · width: all · [`01-home.png`](screenshots/before/customer/375/01-home.png)
`CustomerShell`'s header already has a notification bell with an unread-count badge (shared across all customer pages). `CustomerHomePage.tsx:175-182` adds a second, page-local bell button next to the "Welcome back" heading that navigates to the exact same `/customer/notifications` route — but with no unread badge and no `aria-label` (only a `title`, line 179).
**Severity: High** (two controls for one action, inconsistent with each other, on the single most-visited page). Fix: delete the page-local bell, rely on the shell's.

**CUST-002 — Wrong avatar initials on the Profile page** · Category **C** (Components) + **I** (Content) · `vibe-code` (same logic reimplemented, incorrectly) · role: customer · page: Profile · width: 375px (code-level, applies at all widths) · [`04-profile.png`](screenshots/before/customer/375/04-profile.png), zoomed crop confirms "LA" for "Lakshmi Priya"
The shared `UserMenu.tsx` has a correct `initials()` helper (produces "LP" — shown correctly in every shell header, e.g. the avatar in the very same screenshot). `CustomerProfilePage.tsx:409` instead does `profile.full_name.slice(0, 2).toUpperCase()`, which takes the first 2 *characters* ("La") instead of the first letter of each word, producing **a visibly wrong initial for any customer whose first name is longer than one letter**.
**Severity: High** — this is simply wrong, visible to every customer on their own profile page, right next to their correctly-rendered initials in the header above it. Fix: import and reuse `UserMenu`'s `initials()` helper (or hoist it to a shared util) instead of the inline `slice(0,2)`.

**CUST-003 — Catalog "open product" button has zero accessible name when there's no photo** · Category **J** (Accessibility) · role: customer · page: Product Enquiry catalog · width: all · [`07-product-enquiry.png`](screenshots/before/customer/375/07-product-enquiry.png)
`CustomerCatalogGrid.tsx:132-144`: when a product has no `primaryImage`, the clickable button that opens its detail page renders only a bare `<Package>` icon with no `alt`/`aria-label`/visible text — so the button has **no accessible name at all**. `axe-core` flags this as `button-name` (**critical**), and it hit 3 of the 4 products visible on this page (most catalog products in the test data have no photo uploaded — see CUST-005).
**Severity: Critical** (screen-reader users get nothing for the primary way to open most products). Fix: add `aria-label={p.name}` to the fallback button (or an `sr-only` span), same as the real-photo case already gets via `alt={p.name}`.

**CUST-004 — Mobile "add to compare" checkbox relies only on a `title` attribute** · Category **J** (Accessibility) · role: customer · page: Product Enquiry catalog · width: 375/768px
`CustomerCatalogGrid.tsx:195-203`: the mobile-only compact compare checkbox has no visible text and no `aria-label`, only `title={t("...compare.cta")}` — `axe-core` flags `label-title-only` (serious), since `title` tooltips aren't a reliable accessible name for assistive tech.
**Severity: Medium.** Fix: add `aria-label` alongside (or instead of) `title`.

**CUST-005 — Most catalog products have no photo on file** · Category **D** (States) · role: customer · page: Product Enquiry catalog · width: all
Of the ~13 products visible in the test catalog, only 1 ("Amaron Current 150Ah Battery") has a real photo; the rest show a generic box-icon placeholder. The fallback state itself renders cleanly and consistently (not broken) — this is a **content gap**, not a UI defect, but worth surfacing: customers browsing the catalog mostly see placeholder icons instead of product photos.
**Severity: Low/informational.**

**CUST-006 — Danger-colored text fails contrast app-wide (same pattern as Technician)** · Category **J** (Accessibility) · role: customer · ALL pages
Same systemic `color-contrast` (serious) finding as TECH-007 — hit on 6 page/width combinations here too (the "Technician assigned — tap to track" banner, overdue/status-danger text).
**Severity: High, systemic.** Same fix as TECH-007 — one design-token change in Phase 3 fixes both roles.

**CUST-007 — Icon buttons missing accessible names, systemic** · Category **J** (Accessibility) · role: customer · nearly every page (33 page/width combinations)
`label-content-name-mismatch` (serious), same pattern as TECH-008 — icon-only header/control buttons whose accessible name doesn't match their visible content.
**Severity: Medium, systemic** — fix once at the shared icon-button/header level in Phase 3.

### What's clean (worth recording, not just defects)
- Zero console errors / page errors on any customer page at any width tested.
- No `window.alert()`/`confirm()`, no clickable-`<div>` patterns in `src/app/customer/**`.
- Empty states (My Products, AMC, Compare) all have a clear icon, message, and a next action — no blank tables.
- Booking Detail was caught mid-load during capture: shows a real spinner + "Loading…" text, not a blank screen or layout jump — a genuinely good loading-state example.
- Notification copy is human-readable ("Technician has arrived", "A technician has been assigned to your request") — a sharp, positive contrast with the Technician app's raw-UUID notification bug (TECH-002), confirming that's a real inconsistency and not just how the whole app works.
- The Tamil (`த`) glyph in the language toggle renders correctly via the self-hosted font (verified with a zoomed capture) — no tofu/missing-glyph box.
- Short, human ticket references ("#383a62ef") are used in the Bookings list — another contrast point against TECH-002's raw UUID.

---

## Wave 3 — Admin: all-staff + ops pages

Role: `operation_admin` (covers both the all-staff pages and the ops-only pages in one login). Widths: 1440 and 1024 (primary), 768 (quick check). Pages covered: Dashboard, Workspace, Tasks, Huddle, Notifications, Service Tickets (+ New Complaint, Appointments), Technicians (+ Map, Attendance, Spares), Inventory, Suppliers, Purchase, Complaints, Returns.

**Blocker hit and resolved before this wave could run**: `operation_admin@gvmart.test` and `sales_admin@gvmart.test` were *also* banned, with the exact same timestamp (2026-10-05T11:15) as `customer@gvmart.test` had been — a 3-account batch action, not a one-off. Per the user's explicit instruction, unbanned both and reset both passwords to the standard `GvMart@2026` (same password mismatch as the customer account). **This pattern — 3 of 5 test accounts banned in one batch, all on the same day — doesn't match anything in prior session memory and is worth the user independently investigating.**

### The headline finding: operation_admin appears to have broken data access across most of the admin app

This is a functional/backend finding, not a styling one, and it's **out of this audit's scope to fix** (ground rules: UI/UX only, no business logic/API/data changes) — but it's severe enough, and visible enough in the UI, that it has to be reported prominently rather than buried in a findings list.

**ADMIN-001 — operation_admin sees empty/zero data on nearly every admin page, despite that data demonstrably existing** · Category **H** (UX flows) + **D** (States) · role: operation_admin · ALL widths
Observed, in order:
- **Dashboard** (`01-dashboard.png`): red "⚠ Could not load the tiles" banner with a Retry button, every single page load, at every width.
- **Daily Huddle** (`04-huddle.png`): "Performance —" section shows "Performance numbers unavailable."
- Both trace to the same root cause: `report_sales_service` and `report_ops_resolution` RPC calls return HTTP 400 with `{"message":"not permitted: only staff can view reports"}` — **even though `operation_admin` is defined as a staff role everywhere else in this codebase** (`STAFF_ROLES = [master, operation_admin, sales_admin]` in `router.tsx`). Reproduced on 100% of loads across all 3 widths.
- **Service Tickets** (`06-service-tickets.png`): "No tickets yet," all filter-tab counts (Overdue/Unassigned/Pending/Cancelled/Completed/Missing product) read 0 — despite a real, active, "In progress" ticket existing for this exact org (seen directly in Wave 1, ticket `383a62ef…`, assigned to technician Karthik Raja).
- **Technicians** (`09-technicians.png`): "No technicians yet. Add your first technician to start assigning jobs." — despite a real technician (Karthik Raja) actively working a job in this same org.
- **Inventory** (`13-inventory.png`): "0 SKUs" / "No inventory rows yet." — despite real products with real prices visible in the Customer app's catalog in the same org (Wave 2).
- **Suppliers** (`14-suppliers.png`) and **Purchase** (`15-purchase.png`): both empty, despite prior session memory confirming at least 2 real supplier records exist in this org.

**Ruled out before reporting**: this is not a test-org mismatch — a direct read of the `profiles` table confirms `operation_admin`, `sales_admin`, `technician`, and `master` all share the identical `org_id`. So the data exists in the right org; `operation_admin` specifically can't see it.

**Severity: Critical.** This makes the operation_admin role's primary dashboard, ticket queue, technician roster, and inventory/supplier/purchase modules all appear completely empty on every visit — effectively unusable for anyone actually holding this role in production. Strongly recommend treating this as an urgent backend/RLS investigation, separate from and before any of this audit's Phase 3-5 UI work for ops-role screens (there's limited value polishing table layouts that currently render no rows for this role).

### Other findings

**ADMIN-002 — Inconsistent primary-action button color** · Category **B** (Visual design) · `vibe-code` (same component styled differently) · role: operation_admin · pages: Suppliers, Purchase · width: all · [`14-suppliers.png`](screenshots/before/admin-ops/1440/14-suppliers.png), [`15-purchase.png`](screenshots/before/admin-ops/1440/15-purchase.png)
Every other primary action button sampled this wave ("Assign Task," "Add Technician," "New Complaint") uses the solid black `ink` button style. "Add supplier" and "Create PO" instead use the coral `accent` color. Could be a deliberate "money/procurement" accent, but nothing in the design docs says so, and it reads as inconsistent next to the rest of the admin shell.
**Severity: Low/Medium.** Flag for the Phase 3 design-system pass to make an explicit, documented call either way.

**ADMIN-003 — Month-range control has no accessible label** · Category **J** (Accessibility) · role: operation_admin · pages: Dashboard, Technicians · width: all
`axe-core` flags `label: critical` on the "Month"-range date control (the `#base-ui-...` generated id matches the shared date-picker primitive) on both pages it appears on.
**Severity: Critical** (per axe; a date-range control with no accessible name is unusable via screen reader).

**ADMIN-004 — Notification filter selects look labeled but aren't programmatically associated** · Category **J** (Accessibility) · role: operation_admin · page: Notifications · width: all · [`05-notifications.png`](screenshots/before/admin-ops/1440/05-notifications.png)
The "Type" and "Status" filters are native `<select>` elements with visible text labels right above them, but `axe-core` flags `select-name: critical` on both — the `<label>` text isn't actually wired to the `<select>` via `htmlFor`/`id` or `aria-label`, so it only *looks* labeled.
**Severity: Critical** (per axe), easy fix (add `htmlFor`/`id` pairing).

**ADMIN-005 — Icon buttons with no accessible name on Appointments** · Category **J** (Accessibility) · role: operation_admin · page: Appointments · width: all
`button-name: critical` on 2 icon-only buttons (calendar nav or view-toggle, based on class names).
**Severity: Critical.**

**ADMIN-006 — Danger-colored text contrast failure, systemic (same as Technician/Customer)** · Category **J** · role: operation_admin · 15 page/width combinations
Same `color-contrast: serious` pattern as TECH-007/CUST-006. Confirms this is an app-wide design-token issue, not role-specific.
**Severity: High, systemic.**

**ADMIN-007 — Heading level skip, repeated** · Category **J** · role: operation_admin · pages: Dashboard, Huddle · 6 combinations
`heading-order: moderate`, same pattern as TECH-010.
**Severity: Low.**

**ADMIN-008 — Icon buttons missing accessible names (shell-wide)** · Category **J** · role: operation_admin · pages: Huddle, New Complaint · 6 combinations
`label-content-name-mismatch: serious`, consistent with TECH-008/CUST-007.
**Severity: Medium, systemic.**

**ADMIN-009 — Empty table headers (minor) and a scrollable-region-focus gap at tablet width** · Category **J** · role: operation_admin · Technicians Spares/Suppliers/Purchase (`empty-table-header`, 9 combos, minor); Service Tickets/Technicians Attendance/Inventory at 768px (`scrollable-region-focusable: serious`, 3 combos — a horizontally-scrollable table region isn't keyboard-focusable at tablet width, where tables start needing to scroll).
**Severity: Low (empty-table-header) / Medium (scrollable-region-focusable).**

### What's clean (worth recording, not just defects)
- Empty states throughout (Workspace, Tasks, Inventory, Suppliers, Purchase) have clear icon+message+CTA — consistent with the pattern seen in Waves 1-2, not a vibe-code violation.
- The Dashboard's "Could not load the tiles" error has a proper Retry button rather than a silent failure or a raw stack trace — good defensive UI around a bad underlying permission error (ADMIN-001).
- No `window.alert()`/`confirm()` usage found.
- Admin shell's icon-only sidebar nav correctly uses both `title` and `aria-label` on every nav item (unlike several icon buttons elsewhere in the app).
