# GV Mart — Full Section Audit (2026-10-24)

Read-only audit. Nothing was changed, no files edited, no DB writes made. Row counts
are live production counts pulled via the Supabase Management API on 2026-10-24.
Git history is from `git log --oneline -- <path>` in `gv-mart/`, ignoring repo-wide
sweeps (date-format, i18n, lint passes) unless that was the component's only history.

Legend: **KEEP** / **MERGE INTO x** / **REMOVE**. 🚩 = only path to an action (see
flagged list at the end of each area and the master list at the bottom).

---

## ADMIN AREA

### Dashboard / My Day

| Route | Component | What it does | Reads / Writes | Primary table (rows) | Last substantive commit | Overlap | Recommendation |
|---|---|---|---|---|---|---|---|
| `/admin` (dashboard) | `DashboardPage.tsx` (role-switched Owner/Ops/Sales dashboards) | Role KPI tiles + alerts | R: invoices, expenses, invoice_items, gift_logs, service_visits, ratings, leads, attendance, installations_logged, service_tickets, notifications, tasks, customers, addresses (RPC `report_kpi_tiles`); triggers `refresh_amc_statuses`/`refresh_operational_alerts` | mixed, see Reports | `9491538` (KPI tile strip, feat) | Shares `reports.ts` aggregation with `/admin/reports` | KEEP |
| `/admin/my-day` | `MyDayPage.tsx` | Daily lead follow-up worklist + post-service call queue | R/W: leads, lead_followups, lead_outcomes, settings, post_service_calls | leads 68 / lead_followups 4 | `6f95dce` | Unique — distinct purpose from `/admin/leads` (action queue vs. full CRM record) | KEEP |

### Customers

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/customers` | `CustomersListPage.tsx` | R: customers, addresses | customers **16,385** | `b499fad` | KEEP — backbone of the app |
| `/admin/customers/new` | `CustomerFormPage.tsx` | W: customers, addresses | 16,385 | `248fb6d` | KEEP |
| `/admin/customers/:id` | `CustomerDetailPage.tsx` | R/W: customers, addresses, invoices, invoice_items, warranties, amc_contracts, service_tickets, referral_points, customer_exemption_windows, customer_members, leads, rental_contracts | panels built on near-empty tables (amc_contracts 1, warranties 0, invoices 0, rental_contracts 0) | `c1816cc` | KEEP — the 360° view; its embedded "mark rental returned" action depends on Rentals (see below) |
| `/admin/customers/:id/edit` | `CustomerFormPage.tsx` | W: customers, addresses | 16,385 | — | KEEP |

### Sales / Quotations — ⚠️ never exercised in production

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/sales` | `SalesListPage.tsx` | R: invoices, quotations | **invoices = 0** | `08799ab` | KEEP 🚩 but flag: zero sales ever completed through the app |
| `/admin/sales/new` | `NewSalePage.tsx` | RPC `create_sale` → invoices, invoice_items, amc_contracts, inventory_movements, referral_points | invoices = 0 | `02bd1f8` | KEEP 🚩 — only way to create an invoice, ever |
| `/admin/sales/invoices/:id` | `InvoicePage.tsx` | R: invoices, invoice_items, warranties, service_tickets, amc_contracts, organizations | invoices = 0 — route currently can't render a real record | `580ca3a` | KEEP |
| `/admin/quotations` | `QuotationsListPage.tsx` | R: quotations | **quotations = 0** | `16b5e4b` | KEEP 🚩 |
| `/admin/quotations/new` | `QuotationFormPage.tsx` | W: quotations | 0 | `06bf90d` | KEEP 🚩 — only way to create a quotation, ever |
| `/admin/quotations/:id` | `QuotationDetailPage.tsx` | W: quotations (status/valid_until/lost_reason) | 0 | `580ca3a` | KEEP |

**Owner note:** Sales and Quotations are fully built, load-bearing, and the only entry
points for their respective tables — but neither has ever produced a live row. Not a
code-removal candidate; a real usage gap worth knowing about.

### Leads

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/leads` | `LeadsPage.tsx` | R: leads, lead_items, lead_sources, lead_kinds | leads **68** (live) | `e6c79aa` | KEEP |
| `/admin/leads/:leadId` | `LeadDetailPage.tsx` | R/W: leads, lead_activities, lead_sources, lead_kinds, lead_product_types, lead_followups | 68 | `426de4f` | KEEP |

### Service / Complaints / Returns

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/service` | `TicketsListPage.tsx` | R: service_tickets; shared `ticketFilters.ts` predicate chips (incl. "Overdue") | service_tickets **9** | `b9a9628` (filter chips) | KEEP — merge target for Complaints |
| `/admin/service/new` | `NewComplaintPage.tsx` | W: service_tickets, appointments | 9 | `93114c1` (most recent commit in the whole repo) | KEEP |
| `/admin/service/appointments` | `AppointmentsPage.tsx` | R: appointments, technicians, attendance; W: appointments (reassign) | appointments **8** | `483ec52` | KEEP |
| `/admin/service/:id` | `TicketDetailPage.tsx` | R/W: service_tickets, service_visits, invoice_items, warranties, amc_contracts, technician_locations, attendance | 9 | `4514508` | KEEP |
| `/admin/complaints` | `ComplaintsPage.tsx` — "Overdue SLA" + "Repeat Complaint" tabs, rows link to `/admin/service/:id` | R only: service_tickets | 9 (no own table) | `5cd623d` (untouched since initial build) | **MERGE INTO `/admin/service`** — **confirmed, not just similar**: the Overdue-SLA tab's predicate is byte-identical to `isTicketOverdue()` already powering TicketsListPage's own "Overdue" chip and the Dashboard's "Escalations" card. Only the **Repeat-Complaint** tab (same customer+product >1× in 90 days) is net-new — port it into `ticketFilters.ts` as a 6th chip; drop the Overdue-SLA tab outright |
| `/admin/returns` | `ReturnsPage.tsx` | R/W: returns, invoices (picker) | **returns = 0, and its only data source (invoices) is also 0** | `6dbaf07` (cosmetic); real build `5cd623d`, untouched since | **REMOVE** — strongest removal case in the whole audit: unusable today (nothing to pick in the invoice dropdown), zero feature commits since creation, `returns` referenced nowhere else in the codebase |

### AMC / Rentals

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/amc` | `AmcWarrantyListPage.tsx` | R: amc_contracts, warranties; triggers `refresh_amc_statuses` RPC | amc_contracts **1** (test row per owner), warranties **0** | `c4deb2e` (sweep); real AMC rework per memory 2026-10-12 | KEEP 🚩 — only caller of the status-refresh RPC |
| `/admin/amc/:id` | `AmcContractDetailPage.tsx` | R: amc_contracts, service_tickets, products | 1 — the entire production AMC book is one contract | `4899545` (barely touched since) | KEEP |
| `/admin/rentals` | `RentalsListPage.tsx` + `RentOutPanel.tsx` | R/W: rental_contracts, rental_plans | **rental_contracts = 0 rows, rental_plans = 0 rows — never used, ever** | `057b402` — the ONLY feature commit this file has ever had | **REMOVE is defensible** — self-contained Item-D5 add-on, zero production use. Owner's call, not automatic: it's a working feature, simply unused. If removed: route+nav entry, `RentalsListPage.tsx`, `RentOutPanel.tsx`, `useRentals.ts`, `services/rentals.ts`, the rental read calls inside `CustomerDetailPage.tsx` (incl. the "Mark Returned" button, which becomes a dead button pointed at nothing) and `DeleteCustomerDialog.tsx`'s FK check, the revenue tile in `reportsInsights.ts`, i18n `rentals.*` keys |

---

### Technicians (admin side)

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/technicians` | `TechniciansListPage.tsx` | R/W: technicians, profiles; R: service_visits, ratings, attendance | technicians **2** | `7de0076` | KEEP — hub; other 4 routes are tabs on it |
| `/admin/technicians/map` | `TechniciansMapPage.tsx` | R: technicians, technician_locations, appointments, service_visits, settings | technician_locations **306** (active) | `c4deb2e` | KEEP — only route-overrun/idle alerting view; the writer is the technician app itself |
| `/admin/technicians/attendance` | `TechniciansAttendancePage.tsx` | R only: attendance, technicians/profiles, settings — explicitly read-only by design | attendance **2** | `c4deb2e` | KEEP, consider **MERGE INTO Technicians list as a date-filtered tab** — no unique write path lives here |
| `/admin/technicians/spares` (Handover / Return / Stock Levels tabs) | `TechniciansSpareHandoverPage.tsx` + `TechniciansSpareReturnTab.tsx` + `TechniciansStockLevelsTab.tsx` | RPCs `create_spare_handover`, `create_spare_return` | **spare_handovers/items = 0, spare_returns/items = 0, technician_stock_levels = 0** | `630a5e1` (sweep); feature `687d690` | KEEP 🚩 — **confirmed sole write path**, nothing else creates these rows. Zero rows = unused, not redundant. Don't remove without the owner confirming van-stock tracking is abandoned |
| `/admin/technicians/:id` | `TechnicianDetailPage.tsx` | R/W: technicians, profiles, technician_availability; R: attendance, service_visits, service_tickets, rewards, tiers | technicians 2 | `520c86e` (tier mgmt) | KEEP 🚩 — only delete/password-reset/tier-approval/availability surface |

---

### Inventory / Suppliers / Purchase

| Route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/admin/inventory` | `InventoryPage.tsx` + `InventoryTable.tsx` | R/W: inventory, inventory_movements; R: products/spares/gifts/supplier_products | inventory **267** (active) | `93d99e1` | KEEP 🚩 — only manual stock-correction UI in the app |
| `/admin/suppliers` | `SuppliersPage.tsx` + `SupplierItemsPanel.tsx` | R/W: suppliers, supplier_products | suppliers **2**, supplier_products **15** | `1fca6ec` | KEEP — only place suppliers exist; PO/RFQ pipeline depends on it |
| `/admin/purchase` → Orders tab | `PurchaseOrdersTab.tsx` + PO modals | RPCs `create_purchase_order`, `update_po_items_and_approve`, `mark_po_paid` | **purchase_orders = 0, po_items = 0** | `bf02b1c` | **MERGE candidate** — `create_bill_entry` already allows `p_po_id: null`, i.e. receiving doesn't require a PO. If the owner doesn't want a two-step PO→Bill process, fold "create PO" into Bill Entry and drop the Orders tab + both modals |
| `/admin/purchase` → Quotes (RFQ) tab | `PurchaseQuotesTab.tsx` | RPCs `resolve_purchase_quote_requests`, `log_purchase_quote_reply`, `mark_quote_supplier_no_response` | **purchase_quote_requests/replies/dismissals = 0, 0, 0** | `ea8ea73` | **Strongest REMOVE candidate of the three** — auto-generating cron (`generate_monthly_rfqs`) has produced zero rows, and with only 2 suppliers system-wide, competitive RFQ has little value (N≈1). Remove entirely or fold into a plain "reorder" action |
| `/admin/purchase` → Bills tab | `BillEntryTab.tsx` | RPC `create_bill_entry` → writes `purchase_bills` **and** server-side `inventory` + `inventory_movements` | **purchase_bills = 0** | `2cf22e1` (functional); later hits are sweeps | **KEEP — do not remove.** This is the single most load-bearing row in the whole audit: it is the ONLY code path anywhere that increases stock tied to an actual purchase event (InventoryPage's manual adjust has no supplier/cost/GST trail). Empty table just means no purchase has been logged yet |

**Flagged (purchase):** removing Bills removes the only real "I bought X from supplier Y
for ₹Z" receiving workflow — the only fallback would be the blunt manual stock-adjust
button, with no audit trail at all.

---

### Automation / Campaigns

| Sub-route | Component | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| Automation → Flows | `AutomationFlowsTab.tsx` | R/W: automation_flows | **1 row**, but **nothing downstream ever reads it** (confirmed: `grep supabase/functions` for `automation_flows` = empty) | `ff4a5ae` | **REMOVE or needs-wiring candidate** — a CRUD screen for a table nothing consumes, despite the "flow builder" comment claiming otherwise |
| Automation → Videos | `VideoLibraryTab.tsx` | R/W: video_library | 0 | `d37d925` | KEEP — only admin editor for rows the customer Product Enquiry "video" tab reads directly |
| Automation → Inbox (Inbound Test) | `InboundTestTab.tsx` | RPC `simulate_inbound_whatsapp`; R: whatsapp_outbox | whatsapp_outbox **77** | `630a5e1` | KEEP 🚩 — only way to exercise inbound-bot matching without live WhatsApp credentials |
| Automation → Conversations | `ConversationsTab.tsx` | R: whatsapp_conversations, whatsapp_outbox | whatsapp_conversations **5** | `f9c0d4f` | KEEP — intentional, code-commented overlap with Failed Sends / CustomerDetailPage's WA tab, not accidental dup |
| Automation → Templates | `TemplatesTab.tsx` | R/W: whatsapp_templates | **3** | `f9c0d4f` | KEEP 🚩 — only UI to edit template body/variable_map that milestone/AMC/feedback sends render through |
| Automation → Failed Sends | `FailedSendsTab.tsx` | R only: whatsapp_outbox; R/W: settings threshold | 77 | `ef09003` | KEEP 🚩 — only diagnostic visibility into stuck/failed sends, read-only by design |
| Automation → Jobs | `AutomationJobsTab.tsx` | R/W: settings (job enable/interval) | n/a (proxy: cron_job_heartbeats **5**) | `bbeb630` | KEEP 🚩 — only UI control over cron pacing for the 2 WA jobs |
| Automation → Phrases | `PhraseManagerTab.tsx` | R/W: wa_custom_trigger_phrases | **0** | `02e133e` | KEEP 🚩 — only way to extend bot keyword matching without a deploy; 0 rows = unused so far, not dead |
| `/admin/campaigns` | `CampaignsPage.tsx` | R/W: campaigns (full CRUD) | **campaigns = 0**, and **confirmed zero downstream wiring** — no edge function/cron ever reads it; the page's own UI text admits "no send integration" | `97f2697` (cosmetic); build `a68738c` | **REMOVE — best removal candidate of everything audited.** Real CRUD, but a dead end: creates rows nothing acts on. If removed: nav entry, route, `CampaignsPage.tsx`, `useCampaigns`/`useCreateCampaign`/etc. hooks, `campaigns` CRUD in `systemPages.ts`, `createCampaignSchema`, the `campaigns` table |
| `WaTestModeSwitch` (header control, not a tab) | — | gates `wa_test_mode_enabled`/`wa_test_allowed_numbers` enforced in Edge Functions | — | — | KEEP 🚩 — only UI path to the real test-mode gate; removing it freezes test mode at its last saved value |

---

### Masters (22 top-level tabs, 33 files incl. sub-panels)

| Tab / Panel | Reads/Writes | Primary table (rows) | Recommendation |
|---|---|---|---|
| Brands | brands | 8 | KEEP |
| Models | models | 15 | KEEP |
| Products (+ 6 sub-panels: Media, Spares, Complaints, Attributes, Features/Related, CTA Overrides) | products, product_images/videos/documents, product_spares, complaint_types (product-scoped), product_attribute_keys, product_related, product_cta_overrides | products 15; most sub-tables (product_documents, product_videos, product_related, product_spares) = **0** | KEEP parent; sub-panels are each the only entry point even where 0 rows. **ProductComplaintsPanel duplicates ComplaintTypesTab internally** (same `complaint_types` table, product-scoped vs. category-wide) — consider merging as a filtered view inside Complaint Types |
| Spares (+ Bulk Import, Videos panels) | spares, spare_videos | spares **251** (active); spare_videos **0** | KEEP; Videos sub-panel flagged as a genuinely unused, built-but-unpopulated feature |
| Gifts | gifts | 1 | KEEP |
| Gift Exclusions | gift_exclusion_products | **0** | KEEP for now; **MERGE INTO Gifts** as a sub-section — it's a 0-row feature of Gifts, not its own module |
| AMC Plans | amc_plans, amc_plan_covered_spares | 1 / 0 | KEEP 🚩 — only config for the plan customers buy |
| Rental Plans | rental_plans | **0** (rental_contracts also 0) | **REMOVE candidate** — consistent with the Rentals admin-page finding above; no evidence rentals are used anywhere |
| Technician Tiers | technician_tiers, tier_promotion_eligibility/history | 1 / 0 / 0 | KEEP 🚩 — eligibility/history=0 expected (first cron run unverified per memory), not dead |
| Incentives | incentive_rules | 1 | KEEP, but see Installation Rates below |
| Installation Rates (+ FlatInstallationBonusCard) | installation_incentive_rates/credits; FlatInstallationBonusCard writes `incentive_rules` type='installation' | 0 / 0 | **Internal duplication confirmed**: FlatInstallationBonusCard edits the same `incentive_rules` table as the Incentives tab. **MERGE INTO Incentives tab** as a highlighted filter row |
| Role Salaries | role_base_salaries | 6 | KEEP 🚩 |
| Complaint Types (+ ComplaintTypeSparesPanel) | complaint_types (category-wide), complaint_type_spares | 91 / 0 | KEEP |
| SOP Steps | sop_step_templates, service_sop_steps | 0 / 0 | Flag, don't auto-remove — memory notes SOP checklist (GV.md) was explicitly shipped; verify with owner whether steps were ever defined before treating as dead |
| Product Enquiry (4 config tables) | product_enquiry_tabs/filters/comparison_fields/cta_config | 2–3 rows each, real live config | KEEP 🚩 — feeds the live customer enquiry page |
| Water Quality | water_quality_reference/district_aliases, product_tds_recommendations | 32 / 2 / 3 — all populated | KEEP |
| Lead Sources / Lead Kinds / Lead Product Types | lead_sources (13) / lead_kinds (10) / lead_product_types (10) | — | KEEP each; structurally identical — consider **merging the three into one "Lead Taxonomy" tab** with 3 sub-lists |
| Post Service | post_service_outcomes (10), post_service_calls (0) | — | KEEP — outcomes config is real; calls=0 just means none logged yet |
| Lead Outcomes | lead_outcomes | 22 | KEEP |
| Settings (+ AppointmentSlotsCard, AutoAssignLeadsCard) | settings (singleton), appointment_slots (3), profiles.receives_new_leads | — | KEEP 🚩 all three — don't flag the 1-row `settings` count as unused, it's a true singleton; AppointmentSlotsCard is the only way to configure the 3 live slots customers book against; AutoAssignLeadsCard is the only lead-routing toggle |
| Payment Settings | payment_settings | 1 (singleton) | KEEP 🚩 |

---

### HR / Accounts / Reports / Approvals / Audit Log / Tasks / Huddle / Workspace / Notifications

| Route/tab | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|
| HR → Salary | salaries, technicians, profiles; W: salaries (RPC), **expenses** | salaries **2** | `01e4866` | KEEP 🚩 |
| HR → Staff Salary | profiles, role_base_salaries (6), tasks; W: expenses, profiles | — | `b692209` | KEEP 🚩 — also the only staff-admin CRUD surface (password reset, activate/deactivate) |
| HR → Incentives (+InstallationCreditsPanel) | incentives_earned, incentive_rules, installation_incentive_rates/credits | all **0** | `cbc0975` | KEEP but flag: zero incentives ever computed — verify the compute cron runs |
| HR → Rewards | rewards | **1** | (stale) | KEEP 🚩 — sole path to log a reward, but thin adoption evidence |
| `/admin/accounts` | expenses (+ `getPnlReport` etc.), tasks; **Log Expense panel #1** | expenses **1** (org-wide, shared) | `851e74b` | KEEP as canonical landing page; see duplicate panel below |
| Reports → Sales & Service / Performance / Top Customers / Insights | service_tickets, invoices, ratings (0), leads, customers, products | mixed; `ratings`=0 means Performance's review column and Feedback tab are structurally empty | various | KEEP all; flag `ratings`=0 to owner |
| Reports → P&L | expenses, invoices, invoice_items, gift_logs; **Log Expense panel #2 (duplicate)** | expenses 1 (shared) | `9491538`/`2a7ce2c` | KEEP report; **REMOVE the embedded Log Expense panel** — confirmed literal duplicate of Accounts' panel; its own code comment ("the only place expenses is written from the UI") is already false |
| Reports → Feedback | ratings | **0 — tab currently renders fully empty** | — | KEEP (structurally sound); flag to owner |
| Reports → Coverage | amc_contracts (1), warranties (0), rental_contracts (0), service_tickets | 2 of 3 columns structurally empty | `13216ac` | KEEP, flag |
| `/admin/approvals` | approvals; PO-type approval also updates purchase_orders | **approvals = 0** | `2cf22e1` | KEEP 🚩 — only way to approve/reject a discount, PO, price-override, or leave request, even though never exercised |
| `/admin/audit-log` | audit_log (read-only) | **2,931** — actively populated | `a68738c` | KEEP 🚩 — sole UI reader of the audit trail |
| `/admin/tasks` | tasks | **7** | `cd7bb99` | KEEP as canonical task surface — **MERGE Workspace's task box into this page** |
| `/admin/huddle` | meeting_logs (2), meeting_issues (2); shared `AssignTaskDialog` | — | `c6e6dba` | KEEP — legitimate, distinct purpose (not a duplicate of Tasks) |
| `/admin/workspace` | tasks (same table as /admin/tasks, filtered to self), notifications (read-only widget), appointments (confirmation-call — explicitly a labeled **stub** in i18n) | tasks 7 (shared), notifications 229 (shared) | — | **MERGE: fold task box into `/admin/tasks`** (default "mine" filter); **remove the notifications widget**, deep-link to `/admin/notifications` instead. The confirmation-call stub is not a duplicate of anything — finish it or remove it on its own merits |
| `/admin/notifications` | notifications | **229** | `97f2697` | KEEP 🚩 as the canonical, filterable, mark-all-read surface |

**Expenses correction:** the owner's "three screens, zero rows" claim is close but not
exact — `expenses` has **1 live row**, and there are **four** UI write-paths (Accounts,
P&L, HR Salary, HR Staff Salary), not three. Of those, Accounts' and P&L's panels are a
true duplicate (same form, same hook); the two Salary buttons are legitimately distinct
(salary-specific, not generic expense entry) and should stay.

---

## TECHNICIAN AREA

5 of 16 routes are in the bottom-tab nav (home, map, attendance, history, profile); the
rest are reached only via in-page links.

| Route | Nav | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/technician` | tab "home" | appointments+service_tickets, attendance, technicians, settings | appointments 8 / service_tickets 9 | `c6e6dba` | KEEP |
| `/technician/map` | tab "map" | R: appointments/service_tickets, settings; W: service_visits (open), appointments status, technician_arrival_blocks, addresses patch, technician_locations stream | technician_locations **306** | `895d04d` | KEEP — only geofence-gated visit-start flow |
| `/technician/attendance` | tab "attendance" | R/W: attendance | **2** | `ff4a5ae` | KEEP 🚩 — only check-in/out path; the whole job list is gated behind it |
| `/technician/history`, `/history/:visitId` | tab "history" | service_visits+service_tickets, ratings, leads, service_spares_used | service_visits **1** | `346b8a4` | KEEP |
| `/technician/profile` | tab "profile" | technicians, service_visits+ratings (stats), leads (referrals) | technicians 2 | `0ada6c4` | KEEP — **merge target for Day Sheet** |
| `/technician/spares` | in-page (Home quick action) | R: spare_handovers+items; W: `confirm_spare_handover` RPC | **0 rows** | `687d690` (origin, untouched since) | KEEP 🚩 — only technician-side signature/confirmation step; complementary to admin's handover-creation screen |
| `/technician/spares/history` | in-page (inside Spares) | R: spare_handovers+items | 0 | `687d690` | **MERGE INTO `/technician/spares`** as a History tab — thin reprint list of the same rows |
| `/technician/search` | in-page (Home quick action) | R: addresses→customers→service_tickets; W: call_logs | addresses 11,932; **call_logs = 0, and nothing anywhere ever reads call_logs** | `0ada6c4` | KEEP — no admin equivalent exists; flag `call_logs` as a write-only table worth a separate look |
| `/technician/jobs/:ticketId` | reached from job cards | deep-joined service_tickets read; call button writes call_logs | service_tickets 9 | `25a0fe9` | KEEP |
| `/technician/jobs/:ticketId/route` | in-page (customer-name button) | technician_locations trail, service_visits, appointments | technician_locations 306 (shared with Map) | `ecf5eeb` — **only commit ever**, untouched since | **MERGE INTO `/technician/map`** as a "today's route" toggle — explicitly duplicates the admin trail view per the code's own comment |
| `/technician/jobs/:ticketId/rating` | in-page (from on-site visit close) | W: `ratings` insert, google_review_clicked | **ratings = 0 — table is completely empty in production** | `816700a` | KEEP 🚩 — only writer of `ratings` anywhere; built, wired, never used |
| `/technician/jobs/:ticketId/visit` | in-page (from Map, full-screen, outside shell) | Core on-site stepper: service_tickets/visits, sop_step_templates, service_spares_used, ro_checklists, invoices, service_visit_otps, leads, amc_contracts | Most actively maintained file in the technician area, but several of its own sub-tables are **0** (sop_step_templates, service_sop_steps, ro_checklists, invoices, service_visit_otps, installations_logged) | `d6fb7cc`/`c40dd1a` (ongoing) | KEEP — functional core; flag sub-flows (SOP checklist, RO checklist, OTP, invoicing) as possibly unexercised even though the page itself is actively developed |
| `/technician/day-sheet` | in-page (Profile button) | service_visits/appointments/attendance (today) — pure read summary | shared near-empty tables | `ff4a5ae` (no dedicated commit since) | **MERGE INTO `/technician/profile`** as a "Today" section — duplicates KPIs already on Home and Profile |
| `/technician/notifications` | header bell | notifications (shared hook with admin/customer) | 229 | `366b016` | KEEP — genuinely shared data layer, not a duplicate |
| `/technician/tasks` | in-page (Home quick action) | tasks (shared `useOrgTasks`/`AssignTaskDialog` with admin) | 7 | `cd7bb99` | KEEP — explicit code comment: "sibling of admin's TasksPage, same shared data" |
| `/technician/huddle` | in-page (Home quick action) | meeting_logs/issues (shared hooks, read-only subset of admin's) | 2/2 | `c6e6dba` | KEEP — confirmed read-only subset, not a duplicate |

---

## CUSTOMER AREA

4 of 9 routes are in the bottom-tab nav (home, myProducts, bookings, profile); the rest
are reached only via in-page links.

| Route | Nav | Reads/Writes | Primary table (rows) | Last commit | Recommendation |
|---|---|---|---|---|---|
| `/customer` | tab "home" | customers, addresses, amc_contracts, warranties | amc_contracts 1, warranties 0 | `0ada6c4` | KEEP |
| `/customer/products` | tab "myProducts" | products; W: `register_product_via_qr` RPC | products 15 | `0ada6c4` | KEEP 🚩 — only self-registration path |
| `/customer/bookings`, `/bookings/:id` | tab "bookings" | service_tickets, appointments, technician_locations; W: `submitCustomerRating` RPC | service_tickets 9 | `25a0fe9` | KEEP — flag: `ratings` table is 0 despite a working rating RPC — ratings may be landing inline on the ticket, not in the dedicated table; worth a DB check outside this audit |
| `/customer/profile` | tab "profile" | customers, addresses (11,932), customer_members (4) | — | `be9e3a5`/`c1816cc` | KEEP 🚩 — only self-service address/family management |
| `/customer/amc`, `/amc/:productId` | in-page (Home tile) | amc_plans (1), amc_contracts (1); W: `renewAmcPlan` RPC | — | `93d99e1` | KEEP 🚩 — only customer self-service AMC renew/buy path |
| `/customer/book-service` | in-page (Home/Products/Bookings/AMC) | appointment_slots (3), complaint_types (91); W: `bookServiceTicket` RPC | service_tickets 9 | `7bc5c97`/`0ada6c4` | KEEP 🚩 — only way to raise a new ticket |
| `/customer/product-enquiry`, `/catalog/:productId`, `/callback`, `/compare` | in-page (Home tile) | product_enquiry_tabs (2), products, product_documents/videos/related (all 0); W: `leads`/`lead_items`/`lead_activities` | — | `0ada6c4` | **MERGE callback + compare into product-enquiry** as a modal/step, not separate routes. Catalog/detail itself: KEEP 🚩 — only callback/compare entry point |
| `/customer/spare-enquiry` | in-page (Home tile only) | products, addresses, `product_spares` (**0 — picker has nothing to pick from today**); W: leads/lead_items/lead_activities | — | `5cd623d`/`0ada6c4` | **MERGE INTO product-enquiry** as one more enquiry "kind" value on the same leads pipeline — functionally near-identical write path to callback/product-enquiry. Still KEEP 🚩 as sole entry point until merged |
| `/customer/notifications` | bell icon | notifications | 229 | `0ada6c4` | KEEP |

**Cross-cutting note:** `leads`/`lead_items`/`lead_activities` is the real convergence
point — product-enquiry, callback, spare-enquiry, and book-service's no-match fallback
all write into the same pipeline the admin Leads module manages. A single generic
"Enquiry" page with a type selector could replace 3 of the 4 customer enquiry screens.

---

## MASTER RECOMMENDATION SUMMARY

### REMOVE (strongest evidence — empty tables, no downstream consumer, no feature history)
- `/admin/returns` — unusable today (its own data source is also empty), zero commits since initial build, table referenced nowhere else
- `/admin/rentals` + Masters "Rental Plans" tab — 0 rows ever, one commit total, self-contained
- `/admin/campaigns` — confirmed zero wiring to any send mechanism; the UI itself admits it
- `/admin/automation` → Flows tab — confirmed nothing downstream reads `automation_flows`
- `/admin/purchase` → Quotes (RFQ) tab — auto-generating cron has produced 0 rows; with 2 suppliers system-wide, competitive RFQ has little value

### MERGE
- `/admin/complaints` → `/admin/service` (drop the Overdue tab as pure duplication; port Repeat-Complaint as a new filter chip)
- Reports → P&L's "Log Expense" panel → remove, keep Accounts' panel (literal duplicate)
- `/admin/workspace`'s task box → `/admin/tasks`; its notifications widget → removed, deep-link to `/admin/notifications` instead
- Masters: Installation Rates' FlatInstallationBonusCard → Incentives tab (same table, just filtered)
- Masters: Gift Exclusions → a sub-section of Gifts
- Masters: Lead Sources / Lead Kinds / Lead Product Types → one "Lead Taxonomy" tab (structurally identical)
- `/admin/purchase` → Orders tab → fold into Bill Entry (receiving already works without a PO)
- `/admin/technicians/attendance` → a tab on the Technicians list (read-only, no unique write path)
- Technician `/spares/history` → a tab inside `/spares`
- Technician `/jobs/:id/route` → a toggle inside `/map`
- Technician `/day-sheet` → a section inside `/profile`
- Customer `/product-enquiry/callback` + `/compare` → steps inside product-enquiry
- Customer `/spare-enquiry` → a "kind" value inside product-enquiry's enquiry pipeline

### KEEP but flagged as unexercised in production (do not remove — each is the only path to something)
- Sales / New Sale (`invoices` = 0 ever)
- Quotations (`quotations` = 0 ever)
- AMC (1 contract, a test row; `warranties` = 0)
- Approvals (`approvals` = 0 ever — PO/discount/price-override/leave approval has no other path)
- Technician spare handover/return (0 rows — only confirm/return step, admin creates the handover)
- Technician rating page (`ratings` = 0 — sole writer of the table)
- `call_logs` — written from two technician screens, read by nothing anywhere; worth a separate look
- Masters SOP Steps (0 rows — but memory says GV.md SOP work was shipped; verify before treating as dead)
- Masters Installation Rates / HR Incentives (0 rows computed — verify the compute cron runs)
- Reports → Feedback tab (fully empty — `ratings` = 0)

### Universally cross-referenced tables (expected, not duplication)
`customers`, `service_tickets`, `appointments`, `technicians`, `notifications`, `tasks`,
`leads` — read from many sections for different legitimate sub-views; not a merge
candidate.
