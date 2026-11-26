# Vendor flow fixes (2026-11-25)

## Purpose
Review of supplier → quote → PO → receipt → bill → paid found 5 bugs and 7 gaps. Owner: "fix them all". Payment option chosen: separate payment field (recommended option (a)).

## Architecture
- Migration `supabase/migrations/20261231100000_vendor_flow_fixes.sql`; rollback `supabase/rollbacks/20261231100000_vendor_flow_fixes.rollback.sql` (bodies = live definitions read 2026-11-25).
- Schema: `po_status` + `cancelled`; `purchase_orders.paid_at/paid_by`; `po_items.received_qty`; `purchase_bills.bill_date` (backfilled from expenses); `suppliers.is_active`; unique `supplier_products(supplier_id, item_type, item_id)`; private bucket `purchase-bill-photos` (ops staff, `<org_id>/` folder).
- New helpers (service_role only): `_normalize_in_mobile`, `_queue_supplier_whatsapp` (normalised number, WA test mode, `pending` if v2 dispatch on else `sent`), `_notify_po_not_messaged`, `_send_po_to_supplier`, `_validate_purchase_line`. New RPC `unmark_po_paid` (master). New trigger `approvals_reject_cancels_po`.
- Re-issued: `create_purchase_order`, `approve_purchase_order`, `update_po_items_and_approve`, `_create_po_from_winning_quote`, `_resolve_purchase_quote_requests_core`, `_auto_draft_purchase_order`, `open_monthly_quote_requests`, `create_bill_entry` (now SECURITY DEFINER, explicit org + ops checks), `mark_po_paid`, `_po_task_completed_marks_paid`.
- UI: `src/lib/purchase.ts` helpers; PurchaseOrdersTab (confirm/undo paid, paid badge, cancelled, received-of-ordered), BillEntryTab (sent POs only, PO prefill, photo upload, bill_date), PoReceiptForm (all-zero / negative GST blocked), SuppliersPage (status, 10-digit WhatsApp, delete check), SupplierItemsPanel (errors shown). Zod schemas now used by forms; price must be > 0.

## Impact map
- `wa_supplier_latest_sent_po` (WhatsApp supplier replies): status `sent` now also covers paid-not-received POs — correct (still awaiting delivery).
- Auto-reorder "already in progress" guard (`draft`/`sent`): cancelled POs no longer block; prepaid undelivered POs still block (before: `paid` unblocked → duplicate reorder).
- `wa-scheduled-tasks` → `wa_resolve_purchase_quote_requests` → core: unchanged entry point.
- WhatsApp dispatch: `purchase_quote_request` rows unchanged behaviour. `purchase_order` rows are still never dispatched (not in `MILESTONE_REF_TYPES`) — pre-existing, not changed here.
- `waOutboxSentGuard.test.ts`: migration added to frozen baseline — owner decision pending (see MEMORY.md).
- Reports/expenses: expense still created at receipt; unchanged.

## Edge cases
- Legacy `status='paid'` rows backfilled to sent/received + paid_at (0 live rows at review).
- Already-received POs backfilled `received_qty = qty`.
- 0-qty receipt line skipped; all-zero refused; negative qty refused.
- Bill photo path must start with caller's org id; >5 MB refused client-side and by bucket limit.
- Inactive supplier: not quoted, not a fallback winner, no new PO; replies already logged by an inactive supplier can't win.
- Over-threshold manual PO with no master profile: approval created, no master notified (same as auto path).

## Acceptance criteria
- AC1 Over-threshold PO (manual or auto) stays draft, nothing sent, no payment task; approval sends it.
- AC2 Rejecting a PO approval cancels the draft; auto-reorder works again for its items.
- AC3 Mark paid sets paid_at only; a prepaid PO can still be received; master-only; undo restores and reopens the task.
- AC4 Bill Entry lists only sent POs; server refuses non-sent POs and another supplier's PO.
- AC5 Receipt adds stock to the warehouse row only.
- AC6 Van stock below min opens no supplier quote request.
- AC7 Price ≤ 0, negative GST, other-org item refused.
- AC8 Partial receipt recorded per line + "received short" alert; all-zero receipt refused.
- AC9 Inactive suppliers excluded from quoting/ordering.
- AC10 No valid WhatsApp → no outbox row + admin alert; test mode respected for supplier messages.
- AC11 Duplicate supplier-item link refused with a clear message; deleting a supplier with history explains "set Inactive".
- AC12 Bill date stored and shown; bill photo upload + view.

## Status 2026-11-26
- Merged origin/main in (conflicts: purchase forms now use main's PoItemDraft/"Not set" item type + category check AND this branch's schema validation + bill photo; i18n kept both blocks).
- Renumbered 20261213100000 -> 20261231100000: live already has 20261213100000 = login_activity.
- Drift check: all 10 existing purchase functions on live are byte-identical to the 2026-11-25 rollback snapshot; the 7 new functions don't exist live.
- Rehearsal (rolled back): all post-checks pass (7 new fns, 5 columns, no anon EXECUTE, bill bucket). Data: 1 PO, 2 bills, 2 suppliers.
- Live apply: NOT done — blocked by the session permission check; waits for owner. Do NOT merge to main before apply (UI needs paid_at / unmark_po_paid / new columns).
