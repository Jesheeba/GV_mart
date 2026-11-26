# PLAN — Batch 2026-11-26b: referral sources everywhere + customer quick-add

Branch `feat/referral-sources` (worktree `_local_only/worktrees/referral-sources`, base origin/main c83a0a3). Feature doc: `features/referral-sources.md`.

## 1. Goal and scope
- Every "Referred by" spot (lead forms, New Customer, New Sale, New Complaint, Sell AMC) accepts Technician, Sales person/staff, Existing customer, Someone else.
- "+ Add new customer" inside the customer referrer search: Name, Mobile, Area (optional) → real customer record.
- Customer referrers earn referral points automatically (amount set by master; 0 = off).
- Out of scope: Walk-in/Lead as referrers (they stay Sources — owner decision), customer-app self-referral, backfilling old free-text referrers, changing technician finder credit or staff bonus rates.

## 2. Findings (verified in code, origin/main)
- Sale/Complaint/AMC: technician-only `<select>`; RPC creates a `referral`/`won` lead with `owner_id` = technician → finder credit.
- New Customer: `ReferrerPicker` (technicians + staff incl. sales persons via `list_active_referrers`); no customer option; stored as `customers.referred_by_user_id` (set-once guard).
- Lead form: Source-driven (`ReferredBySection`); customer referrer only copied as free-text name/phone; no customer column exists anywhere.
- `create_customer_with_details` already accepts a customer with no address → quick-add needs no new RPC.
- Referral points: `referral_points` ledger + manual `award_referral_points` only.

## 3. Project memory respected / changed
- DB writes only on the owner's exact words; migration built + tested in a rolled-back transaction, applied on "go apply".
- Changes the 2026-11-11 "Referred-by fully source-driven" decision: the Referral source now shows a referrer-type chooser.
- 2026-11-02 incentive stream listed `create_customer_with_details`, `_lead_apply_status` and complaint functions as owned by another window → owner must confirm that's closed before R3.
- Live function bodies md5-pinned before editing; DROP FUNCTION → re-grant (2026-11-11 lesson).

## 4. Build order
1. R1 `ReferrerField` + `QuickAddCustomerDialog` (frontend, no DB) — wired into lead forms and New Customer for the kinds that already persist.
2. R2 DB migration: `referred_by_customer_id` columns + guards, RPC params, carry-over, `_record_transaction_referrer` — waits for "go apply".
3. R3 Wire Sale / Complaint / AMC + customer-referrer display on detail pages.
4. R4 Auto points: setting + invoices trigger + Masters setting UI — waits for "go apply" (can ship in the R2 migration if approved together).

## 5. Open decisions (owner)
- Q1 Points per referred customer (setting; starts at 0 = off until you set it).
- Q2 When points are credited: on the referred customer's **first invoice** (recommended — fake customers earn nothing) vs as soon as the customer is created.
- Q3 Confirm the 2026-11-02 "other window owns create_customer_with_details / complaint functions" rule is no longer active.

---

# PLAN — Batch 2026-11-26: picker search, GST incl/excl, quick-add

Branch `fix/sales-search-gst-quickadd` (worktree `_local_only/worktrees/sales-search-gst-quickadd`, base origin/main feaaa84).

## 1. Goal and scope
- F1 `picker-search`: staff can type to find spares/products in New Sale (and Quotation/PO, same pickers); multi-word search works; product labels stop repeating text.
- F2 `gst-inclusive-toggle`: bills can treat entered prices as GST-inclusive or GST-exclusive. Never existed before (checked all branches/history) — this is new, not a regression.
- F3 `quick-add`: "+ Add" inside pickers for master lists, starting with Name of complaint.
- Out of scope: redesigning masters pages, changing price lists, bulk re-import of the spreadsheet.

## 2. Root causes found (verified in code + live DB, read-only)
- Spares picker on New Sale is a native `<select>` with 170 rows all starting "ROS …". Native type-ahead treats Space as "open/confirm", so typing "ROS AD…" stops at the space. No search box exists.
- Product search (`productMatchesQuery`) is a single substring match on "brand model name" → word order / skipped words ("rop blue") return nothing.
- "Double" product text: all 34 products came from a spreadsheet import with brand = `RO (spreadsheet import)` and model = product name minus "ROP ". Label `brand model — name` prints e.g. "RO (spreadsheet import) 2090 BLUE — ROP 2090 BLUE".
- One real near-duplicate product: "ROP WALLMOUNT FILTER WITHOUT RO" vs "ROP WALLMOUNT FILTER (WITHOUT RO)". No duplicate spares.
- GST today is always added on top (`gst = (subtotal-discount) × rate`), computed authoritatively in 6 live RPCs (create_sale→_sale_create_line_invoice, create_service_invoice, sell_amc_plan_onsite, create_rental, run_rental_billing).
- Every master table (complaint_types, lead_sources/kinds/product_types, brands, models, products, spares) is write = master-only by RLS. New Complaint is open to master + operation_admin, so a plain client-side quick-add fails for operation_admin.

## 3. Project memory respected
- DB writes need the owner's exact authorization words ([[gv-mart-no-db-write-unless-named]]); F1 is code-only. F2/F3 migrations are built + tested, applied only on "GO APPLY".
- Worktree-only git; commit per feature; never push to main.

## 4. Build order
1. F1 (no DB, unblocks billing today).
2. F3 complaint quick-add (small RPC if non-master roles need it).
3. F2 GST (largest; touches every billing RPC + invoice print).

## 5. Open decisions (owner)
- D1 Real brand name to replace `RO (spreadsheet import)`; archive which near-duplicate product.
- D2 GST toggle granularity (org default + per-bill override recommended).
- D3 Quick-add for operation_admin/sales_admin (RPC) or master-only.
- D4 Which other pickers get quick-add.

---

# PLAN — Leads Dashboard Enhancement

## 1. Goal and scope
Enhance the existing **Leads** feature (`gv-mart/src/app/admin/leads/`) to match `lead_dashboard_prototype.html` / `lead_dashboard_requirements.md`: 6 status tiles, cleaned-up filters, a visible lead-category chip bar, richer lead-detail capture, a real "followed by" concept, and reminder-integrated follow-ups.

**Out of scope:** new CRM, new lead-assignment logic, changing `assigned_to`/round-robin behavior, touching water-quality TDS features, rebuilding `lead_activities`/`lead_followups`/`tasks`.

## 2. Project memory / prior decisions respected
- `leads.kind`/`kind_key` already *is* the service/product/spare/amc category (masters-backed). **Do not add a duplicate `lead_category` column** — expose it as chips instead.
- `tasks` table + `workspace.ts` (`createTask`/`setTaskStatus`, generic `ref_type`/`ref_id`) already *is* the reminder/task system. **Do not build a new reminder table.**
- `lead_activities` (append-only, actor+timestamp) + `lead_followups` (RPC-only writes, full audit) already *is* follow-up history. **Do not add an overwritable notes field.**
- `leads.assigned_to` is trigger-protected (only `assign_lead` RPC may write it) — new work must not write it directly.
- House style for new sensitive tables: SECURITY DEFINER RPC writes, not permissive RLS (see `lead_followups`).
- A recent migration (`20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer*`) restructured `leads`/`customers` RLS — re-read it before writing any new RLS on `leads`.

## 3. Decisions (confirmed with user 2026-11-10)
1. **TDS.** Confirmed: this is the same water-TDS concept used elsewhere in the app, not a tax term — my initial read was wrong. No renaming needed. Column: `tds_status` (`select | applicable | not_applicable | to_be_confirmed`), label "TDS", same terminology as the rest of the app.
2. **Referral details.** Confirmed: keep both — existing `referred_by_user_id`/`ReferrerPicker` (bonus-points flow) stays as-is; add new free-text `referred_by_name`/`referred_by_phone` fields for referrers not in the system. Shown separately, not merged.
3. **"Followed by" vs "Assigned by".** Checked the actual RLS/RPCs first (not assumed): today's system does **not** technically restrict follow-up *logging* (`log_lead_outcome`, `add_lead_note`) to the lead's assignee — only *scheduling* the next follow-up (`set_lead_followup`) is ownership-gated. So assignee and follow-up-actor can and do diverge in practice. Confirmed: ship "Followed by" as a new, additive filter based on actual `lead_activities.created_by`; keep the existing assignment filter unchanged, unrenamed.
4. **Upload report/document.** Confirmed: single file per lead for v1 (`report_storage_path` column + bucket + RPC). Extend to multi-file later only if actually needed.
5. **Sixth metric tile.** Resolved by existing schema — `lead_status` enum is `new | contacted | quoted | won | lost`. Tile 4 label "Quotation" maps to DB value `quoted`; tile 6 is `lost`. No open question.
6. **"All topics" removal.** `enquiry_type` (the "topic" column/filter) stays as a DB field — only its dedicated filter UI is removed; its context moves into free-typing via **Special description**. Existing leads keep their `enquiry_type` data; only the filter is hidden.

All decisions now confirmed — see `build-docs/MEMORY.md`. Ready to implement per the build order in §4.

## 4. Feature list, prioritized (build order = dependency order)
1. **[lead-category-chips](features/lead-category-chips.md)** — filter cleanup, chip bar for existing `kind`. No migration. Lowest risk, do first.
2. **[lead-summary-tiles](features/lead-summary-tiles.md)** — 6 status tiles with count+%. No migration, pure read.
3. **[followed-by-filter](features/followed-by-filter.md)** — new filter + per-person counts from `lead_activities`. No migration (reads existing table), but new query/RPC.
4. **[lead-detail-fields](features/lead-detail-fields.md)** — migration adding `customer_requirement`, `special_description`, `user_source`, `budget`, `tds_status`, `report_storage_path` + storage bucket + RPC.
5. **[referral-details](features/referral-details.md)** — migration adding `referred_by_name`, `referred_by_phone`. Depends on decision #2.
6. **[followup-workspace-reminders](features/followup-workspace-reminders.md)** — wires "Today's conversation" → `lead_activities` insert, "Next follow-up" → existing `SetFollowupDialog`/`lead_followups`, "Reminder" → `tasks` (`ref_type='lead'`). Depends on #3 decision and features 1–3 landing first (shares the detail page layout).
7. **[lead-unified-interaction-log](features/lead-unified-interaction-log.md)** — DONE 2026-11-11. Merged the three separate "Log Outcome" / "Reschedule" / "Today's Conversation" entry points into one "Log interaction" sheet so a lead's stage, postpone_count/stuck flag, and next follow-up move correctly no matter which mode staff use. No migration, no new RPC — client-side consolidation only, reusing `log_lead_outcome`/`reschedule_followup`/`add_lead_note` as-is.

Each feature ships as its own commit per the global workflow (design doc already written below; tests + build-docs updates happen per-feature during implementation, not now).

## 5. Build order rationale
Chips/tiles/filter (1–3) touch no schema and are safe to ship first, independently reviewable. Detail-field and referral migrations (4–5) are additive-only (`alter table ... add column`, nullable) so they don't block 1–3. Reminders (6) depends on the detail page already having its new layout from 1–3 and the follow-up actor concept from 3.

## 6. What happens after approval
Per-feature loop: design doc (already written) → impact check → implement (Ponytail) → write tests → run → fix root causes → regression check on that feature's impact map → update `build-docs/TESTING.md` + `CHANGELOG.md` → commit `feat(lead-<name>): ...` → push → short status → next feature.

---

# PLAN — UX pass: choices, input density, dates (2026-11-26)

## Goal and scope
- Fix the owner's three usability complaints across the whole app:
  1. options pre-selected, so staff choose blindly;
  2. oversized inputs for short numbers;
  3. dates wrapping or split over extra rows.
- **Out of scope:** visual redesign, colours, new components, any DB change, changing existing saved data.

## Project memory respected
- Check before build: every target came from the 2026-11-26 inventory, nothing duplicated. SegButton, Input and formatDate helpers are reused.
- Dropdown request challenged; the owner approved "buttons with no pre-selection + required" (MEMORY.md).
- Worktree-only git; one commit per feature; build, test, stop for review.

## Features, build order
1. **[choice-no-preselect](features/choice-no-preselect.md)**: most impact (money and customer data recorded blindly). Phase A1 address + payment method, then A2 everything else + EntityCrudTable.
2. **[input-density](features/input-density.md)**: B1 most-used screens, then B2 the rest.
3. **[date-display](features/date-display.md)**: independent; last, because it touches list pages the other two don't.

Each phase gets: tsc -b + vite build, vitest (validation schemas, formatDate helpers), a 390px and 1280px screenshot check of every touched screen, and a commit and merge to main after owner OK.

## Blocker for screenshot checks
- The `.env.test` master login is rejected on local dev.
- Needed: either reset the `master@gvmart.test` test password (then update `.env.test`), or reconnect the Chrome extension.

---
# Rework (2026-11-26) — PLAN v3, all questions answered, awaiting go-ahead for R1
- Goal: a completed complaint with the same problem returning is redone free, by the same technician by default, tracked against them; technician can choose Paid (new problem) or dispute "not a rework"; master decides.
- Out of scope: incentive deductions (`compute_salary` owned by the incentive stream), new WhatsApp templates, automatic refunds.
- Design, impact map, edge cases, acceptance criteria, build order R1–R5, open Q1–Q6: [features/rework.md](features/rework.md).
