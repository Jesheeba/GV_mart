# Changelog

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
