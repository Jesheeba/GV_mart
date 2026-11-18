# Changelog

## Arrival Location Mismatch Alerts — 2026-11-18
Built, committed, NOT applied to live DB (owner must say "GO APPLY" per [[gv-mart-no-db-write-unless-named]]), NOT pushed.

- New migration `20261212120000_arrival_location_mismatch_notify.sql`: AFTER INSERT trigger on
  `technician_arrival_blocks` → `_notify_arrival_block()`, creates one open task
  (`ref_type = 'arrival_location_mismatch'`, assigned to oldest active operation_admin/master) +
  one `notifications` row (role `operation_admin`) per customer whose pin a technician couldn't
  reach — same fail-safe/dedup/flood-cap shape as `20261204140000_customer_needs_review_notify.sql`.
  Rollback: `supabase/rollbacks/20261212120000_arrival_location_mismatch_notify.rollback.sql`.
- `TaskDetailDialog.tsx`: new "View customer" block for this task type (mirrors the existing
  `isCustomerNeedsReviewTask` block).
- i18n: `tasks.arrivalMismatch*` + `notifications.types.arrival_location_mismatch[_flood]` (en/ta).
- Feature doc: `build-docs/features/arrival-location-mismatch-alerts.md`.
- Full suite 1078/1080 passing (2 pre-existing unrelated failures in `waOutboxSentGuard.test.ts`
  and `wa-event-context.test.ts`, not touched by this change).

## Segment Builder (advanced/secondary automation) — 2026-11-13
Built, not committed/pushed, not applied to live DB (blocked, see TESTING.md).

- New migration `20261204230000_segment_builder.sql`: `audience_segments`, `audience_segment_runs`,
  `audience_segment_recipients` tables; `customers.marketing_opt_out` column; a condition-tree
  evaluator (`_segment_tree_match`/`_segment_leaf_match`) over customer + purchase/AMC/warranty
  attributes; `audience_segment_match_count`/`_preview`/`_send_now`/`_set_standing` functions; a
  standing-mode trigger on `invoice_items` insert. Master-only RLS throughout.
- `wa-event-context.ts`: new `audience_segment_match` ref_type branch.
- New admin UI: `SegmentsTab.tsx` (condition builder, save/reuse, preview, template pick, Send Now,
  Standing toggle, results) under Automation → Segments.
- `src/services/audienceSegments.ts`, `src/hooks/useAudienceSegments.ts`.
- 3 new tests in `wa-event-context.test.ts`; full suite 1035/1036 (1 pre-existing unrelated failure,
  see TESTING.md).
- `supabase/test-customer-guard.manifest.json`: added `audience_segment_match_count`.

## Basic Lifecycle Automation (gvm_* templates) — 2026-11-12/13
Built earlier this session, not committed/pushed, not applied to live DB (blocked).

- Migrations `20261204210000_wire_gvm_templates_phase_a.sql` (7 existing triggers →
  Wasi-approved templates) and `20261204220000_wire_gvm_templates_phase_b_new_triggers.sql`
  (5 new triggers: lead created, quotation generated, AMC registered, payment received,
  installation completed).
- `wa-event-context.ts` extended for the new ref_types.
- New admin UI: `EventTemplatesTab.tsx` — per-event on/off toggle.
- Known gap: payment trigger only fires for ticket-linked payments (no template exists yet for a
  plain product-sale receipt).
