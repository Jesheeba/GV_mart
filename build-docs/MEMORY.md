# MEMORY — build-docs project memory

## Decisions made (2026-11-10)
- TDS field is the water-TDS domain concept, same as elsewhere in the app — not tax. No renaming needed; column `tds_status`, label "TDS". (My initial read of the requirements doc as "Tax Deducted at Source" was wrong — corrected by user.)
- Referral: **correction 2026-11-10** — verified in code before building feature 5; there is no `referred_by_user_id` column on `leads` and no `ReferrerPicker` component (the earlier codebase survey was wrong on this point). The existing "referral" UI on `LeadDetailPanel.tsx` is just a manual "Award referral points" action (search a customer via Autocomplete, give points) — nothing is persisted on the lead record itself. So there's no coexistence to manage: `referred_by_name`/`referred_by_phone` are simply new, free-text columns, added without touching the existing points-award flow.
- "Followed by" ships as a new, additive filter based on `lead_activities.created_by`; existing assignment filter stays unchanged, unrenamed. Confirmed after checking the actual RLS/RPCs: follow-up *logging* (`log_lead_outcome`, `add_lead_note`) is not restricted to the assignee today — only *scheduling* (`set_lead_followup`) is ownership-gated — so assignee and follow-up-actor genuinely diverge in practice; this isn't just a hypothetical distinction.
- Document upload: single file per lead for v1 (`report_storage_path`), not a multi-file table.
- `leads.kind`/`kind_key` = lead category; no new `lead_category` column (confirmed by codebase survey).
- Reuse `tasks` table for reminders; no new reminder table (confirmed by codebase survey).
- Follow-up history stays append-only in `lead_activities`/`lead_followups`; no overwritable notes field.

## Constraints
- `leads.assigned_to` writable only via `assign_lead` RPC (trigger-enforced) — never write it directly from new code.
- `lead_followups` has no insert/update RLS by design — all writes go through RPCs (`log_lead_outcome`, `reschedule_followup`, `set_lead_followup`, `reopen_lead`, `add_lead_note`). Follow this pattern for any new sensitive table.
- Migration `20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer*` recently restructured `leads`/`customers` RLS — re-read it before writing any new RLS on `leads`.
- `alternate_mobile`/`address_text` columns from `20261201110000_lead_edit_details.sql` were noted in a hand-comment as "not applied yet" as of the survey — verify current migration status before assuming they exist in prod.
- `set_lead_followup` is ownership-gated via `_lead_set_followup_allowed()` (sales_admin can't schedule on someone else's lead; master can). `log_lead_outcome`/`add_lead_note` are not gated this way — any sales staff in the org can log on any lead. This asymmetry is pre-existing, not something this feature should "fix" unless separately asked.

## Open questions (business, not technical)
- None blocking — all 4 flagged decisions confirmed 2026-11-10. See PLAN.md §3.

## Live-DB divergence found 2026-11-10 (before applying the feature 4/5 migrations)
- This worktree's `supabase/migrations/` only went up to `20261103120000` locally, but the live DB's `supabase_migrations.schema_migrations` already had migrations up to `20261204190000` — applied by other concurrent sessions (expected per [[gv-mart-deliberate-parallel-sessions]]), not yet reflected in this branch's git history or hand-patched `database.ts`.
- Concretely: `leads.referred_by_user_id` and `leads.referral_type` exist live today but are absent from this worktree's `database.ts` — the earlier "no referred_by_user_id exists" claim in this doc (and in referral-details.md) was checked against the stale local checkout, not the live schema, and was wrong for live reality. Harmless here (my new columns were independent and additive regardless), but **next time, verify assumptions about "does X column exist" against the live DB with a direct query, not just the local `database.ts`/migrations folder** — they can and do diverge.
- Confirmed no collision before applying (checked `leads` columns, `lead-reports` bucket, `record_lead_document` function, `leads_update_sales` policy, and the three helper functions my RPC/policies use — all either absent-as-expected or present-and-compatible).

## Known issues / risks
- `CreateTaskInput` in `workspace.ts` may not yet expose `ref_type`/`ref_id` params even though the `tasks` table has the columns — must verify before building feature 6 (followup-workspace-reminders).
- Rescheduling an existing follow-up with an active reminder task could orphan a stale task if not explicitly handled — flagged in followup-workspace-reminders.md, needs a small design check during implementation.
