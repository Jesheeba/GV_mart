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
