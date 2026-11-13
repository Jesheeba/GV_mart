# Feature: Segment Builder (advanced/secondary automation, Phase 1+2 combined)

Per owner decision 2026-11-12 (recorded in `PLAN.md`): multi-condition AND/OR filters, saved/reusable named segments, BOTH one-off and standing fire modes, master/admin only.

## Purpose
Let a master/admin build an audience from any combination of customer + purchase attributes (e.g. "bought Amaron battery" AND "city = Chennai" AND "no AMC yet"), save it by name, pick an approved template, preview, and send — either once now, or as a standing rule that auto-fires on every future matching purchase.

## Data model
- `audience_segments`: `id, org_id, name, condition_tree jsonb, created_by, created_at, updated_at`.
- `condition_tree`: `{ op: 'and'|'or', conditions: [ {field, operator, value} | <nested tree> ] }`. Fields: customer (`city`, `status`, `tags`), purchase (`product.brand`, `product.category`, `product.name`, `purchase_date`), contract (`has_active_amc`, `has_active_warranty`).
- `audience_segment_runs`: `id, segment_id, template_id (wasi_template_name), fired_at, mode ('manual'|'standing'), matched_count, sent_count, failed_count`.
- `audience_segment_recipients`: `run_id, customer_id, outbox_id, status` — per-recipient result, joined to existing `whatsapp_outbox`.
- Standing mode: a row in the existing (currently dormant) `automation_rules` table, condition = the segment's `condition_tree`, action = "queue send via this segment's chosen template." Reuses existing schema instead of inventing new plumbing per PLAN.md.

## Flow
1. Admin builds/edits a segment's condition tree in a visual builder (add condition, pick field+operator+value, group with AND/OR).
2. Live match count shown as they build (runs the tree as a SQL filter against a view joining customers+invoice_items+products+amc_contracts+warranties).
3. Save segment with a name — reusable later.
4. Pick an approved template (from already-approved `gvm_*` list), preview rendered message per a few sample customers.
5. Send Now (one-off): queue paced sends via existing `sendMessage()`/`whatsapp_outbox` path, skip opted-out, record run + per-recipient results.
6. OR Make Standing: write an `automation_rules` row; a new trigger re-evaluates only the newly-changed row (new purchase, new customer attribute) against any active standing segment, firing one send per match — not a full re-scan.
7. Results view per run: matched/sent/delivered/failed.

## Safety / edge cases
- Zero matches → block send, show 0.
- Customer already sent this exact segment+template within N days → skip, don't duplicate (dedupe window configurable, default 7 days).
- Opt-out flagged customer → excluded, counted separately.
- Missing merge field for a specific customer → that customer skipped with reason, rest still send.
- Master/admin role only (RLS `is_ops_staff()`-equivalent, follow existing `whatsapp_event_templates` policy pattern).
- Does not touch or weaken the basic lifecycle automation (12-template wiring) built earlier this session — fully separate tables or additive only.

## Acceptance criteria
- Can build a 3-condition AND segment and see a correct live match count against real data.
- Can save, reload, and reuse a segment with a different template.
- One-off send respects pacing, opt-out, dedupe; results view shows accurate counts.
- Standing mode: a new matching purchase auto-queues a send without any manual action, using the same template.
- No regression in existing 246 tests.
