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
