# ARCHITECTURE — Leads Dashboard Enhancement

Enhancement to an existing feature; this records only what's new or changed.

## Existing pieces reused as-is
- `leads` table (`gv-mart/src/types/database.ts:5377-5546`), enums `lead_status`, `lead_kind`, `enquiry_type`.
- `lead_activities` — append-only follow-up timeline, `created_by` = actor.
- `lead_followups` — structured scheduling/outcome, RPC-only writes (`log_lead_outcome`, `reschedule_followup`, `set_lead_followup`, `reopen_lead`).
- `tasks` + `task_logs` (`gv-mart/src/services/workspace.ts`) — generic reminder/task system via `ref_type`/`ref_id`.
- `useLeadSourceOptions`, `useLeadKindOptions`, `useLeadProductTypeOptions` — masters-backed dropdowns.
- Storage-upload convention: private bucket, path `${orgId}/...`, write via SECURITY DEFINER RPC, read via signed URL (`paymentProofs.ts`, `technicianDocuments.ts`).

## New pieces
- **UI only:** category chip bar (`LeadsPage.tsx`), 6-tile summary strip (reuse `kpiTilesView.ts` pattern or an inline leads-scoped equivalent), "Followed by" filter control.
- **New read query/RPC:** per-actor distinct-lead-count from `lead_activities` (for "Followed by" filter + reporting).
- **New columns on `leads`** (additive, nullable): `customer_requirement text`, `special_description text`, `user_source text`, `budget numeric`, `tax_tds_status text` (enum-like, checked via `check` constraint: `select | applicable | not_applicable | to_be_confirmed`), `report_storage_path text`, `referred_by_name text`, `referred_by_phone text`.
- **New storage bucket:** `lead-reports` (private), + RPC `record_lead_document(p_org_id, p_lead_id, p_storage_path)`.
- **New call sites of existing systems:** `createTask({..., source:'lead_followup_reminder', refType:'lead', refId: lead.id})` from the lead detail follow-up panel (requires confirming `CreateTaskInput` actually accepts `ref_type`/`ref_id` — verify in `workspace.ts` before implementing; survey only confirmed the columns exist on the table, not that the TS helper exposes them yet).

## Data flow for one follow-up cycle (new/changed path only)
1. Staff opens lead detail → "Today's conversation" textarea → on save, inserts one row into `lead_activities` (`created_by` = current user, `at` = now, `note` = text).
2. "Next follow-up date/time" → existing `SetFollowupDialog` → `set_lead_followup` RPC → row in `lead_followups`, trigger updates `leads.next_followup_at`.
3. "Reminder" selector → if set, `createTask` with `ref_type='lead'`, `ref_id=lead.id`, `due_at` = chosen next-follow-up datetime minus lead time.
4. "Followed by" filter on the Leads list → query distinct `lead_id` per `lead_activities.created_by` (scoped by org + existing RLS), joined back to the filtered lead list.

## Impact map (modules touched)
| Module | Touched by | Risk |
|---|---|---|
| `LeadsPage.tsx` | 1, 2, 3 | Filter/stat layout change only; existing `assignedFilter`, `quick` pills untouched |
| `LeadDetailPage.tsx` / `LeadDetailPanel.tsx` | 4, 5, 6 | New fields/sections added; existing stage buttons, quotation, referral-points block untouched |
| `NewLeadForm.tsx` | 4, 5 | New optional fields added to create flow |
| `MyDayPage.tsx` | 6 (reminder only) | Only if reminders surface there via `tasks`; verify `ref_type='lead'` doesn't collide with existing task list filters |
| `workspace.ts` | 6 | May need `refType`/`refId` added to `CreateTaskInput` if not already present |
| `kpiTilesView.ts` | 2 (optional) | Only touched if tiles are built on the shared pattern instead of a leads-local computation |
| DB migrations | 4, 5 | Additive nullable columns + 1 bucket + 2 RPCs; no destructive change |
| RLS | 4, 5 (storage), none for 1-3 | New bucket needs its own storage policies; table RLS for `leads` unchanged (new columns inherit existing row policies) |
