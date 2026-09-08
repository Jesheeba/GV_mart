# Supplier Monthly RFQ → Lowest-Price PO → Approval → Receipt Pipeline

Built 2026-09-01/02, all four phases live, deployed, and end-to-end tested (SQL-level + real signed webhook calls + Playwright against production builds). This is the reference doc for any future work on this pipeline — read it first, the way `GV_MART_FINAL_BOT_SPECIFICATION.md` is for WhatsApp bot work.

## What it does, end to end

1. On an admin-set day of each month, every product/spare with at least one linked supplier gets a fresh WhatsApp price-quote request sent to every linked supplier.
2. Supplier replies (text or, for the receipt-check step, any reply at all) are parsed **deterministically — no AI, pure regex** — per the owner's zero-AI decision (see `gv_mart_whatsapp_zero_ai_pivot` memory).
3. Once replies resolve, only items **still actually at/below minimum stock** get a purchase order auto-drafted from the lowest bidder; everything else just refreshes its price-comparison data.
4. If `settings.po_requires_approval` is on, the draft PO doesn't send until a **master** approves it via a blocking red popup — quantities are editable there first.
5. Once sent, any WhatsApp reply from that supplier (with no open quote request) triggers a second red popup asking master/operation_admin to confirm what actually arrived — received quantities are editable, defaulting to ordered — and only on confirmation does inventory increase.

## Phase-by-phase

### Phase 1 — settings + deterministic price parsing + price freshness
- `settings.po_quote_day_of_month` / `po_quote_last_run_month` — new columns, surfaced in Settings → Inventory Defaults card.
- `supabase/functions/_shared/whatsapp-extract-quote-deterministic.ts` — regex-based price extraction (labeled / currency-prefixed / currency-suffixed / bare-number), replaces the old Anthropic-based `whatsapp-extract-quote.ts` (kept in repo, unused). Wired into `handleSupplierReply` in `whatsapp-handle-message.ts`. `settings.wa_quote_extraction_enabled` (same column, same Automation-page toggle) now gates this deterministic parser instead of an AI call.
- Every successful reply (auto-parsed or manually logged) writes the price straight back into `supplier_products.price` / new `price_updated_at` column — this is what keeps `SupplierItemsPanel.tsx`'s "Updated" column current.
- Migration: `20260901100000_supplier_monthly_rfq_phase1.sql`.

### Phase 2 — the monthly trigger, reliable resolution, low-stock gate, no-response marking
- `open_monthly_quote_requests(p_org_id)` (service-role only) — IST-aware, atomic day-of-month + once-per-month claim (single `UPDATE...WHERE`, same idiom as `approve_purchase_order`). Called every 5-minute tick from `wa-scheduled-tasks`; no-ops except on the configured day.
- `resolve_purchase_quote_requests` split into a shared `_resolve_purchase_quote_requests_core` plus a new service-role twin `wa_resolve_purchase_quote_requests`, now called from the same 5-minute sweep so requests resolve reliably instead of only "on view" (Purchase → Quotes tab mount).
- **Low-stock gate**: the core resolver now checks `inventory` (location `warehouse`) before creating a PO — only genuinely low-stock items get one; others resolve to a new `no_po_not_low_stock` status, price still recorded.
- `purchase_quote_dismissals` table + `mark_quote_supplier_no_response(request_id, supplier_id)` RPC — lets an admin mark a supplier as not going to reply; purely a display concern (resolution logic already only considers actual replies).
- Price comparison table in `PurchaseQuotesTab.tsx`'s `OpenRequestCard` — every invited supplier, side by side, lowest reply highlighted, "Mark as no response" per un-replied supplier.
- Migration: `20260901110000_supplier_monthly_rfq_phase2.sql`.

### Phase 3 — PO approval red popup, editable quantities
- `update_po_items_and_approve(p_approval_id, p_items)` — superset of `approve_purchase_order`: claims the approval FIRST (closes the edit-race), then applies per-line quantity edits (scoped to that PO only), recalculates the total, then does the same dispatch/notify. Stays `is_master()`-gated.
- New RLS policy `approvals_select_po_ops` — lets `operation_admin` (not other roles) *view* `type='po'` approvals; every other approval type stays master-only.
- `PoApprovalPromptModal.tsx`, mounted in `AdminShell.tsx` — ShiftEndPromptModal pattern (realtime + on-load fallback, blocking). Master gets editable qty + Approve/Reject; operation_admin sees the same data read-only with a "waiting on a master" note. Both close automatically once anyone resolves it.
- Migration: `20260901120000_supplier_monthly_rfq_phase3.sql`.

### Phase 4 — receipt-confirmation red popup, admin-gated inventory increase
- `wa_supplier_latest_sent_po(p_org_id, p_supplier_id)` — service-role RPC backing the deterministic "did it arrive" trigger in `handleSupplierReply`: no open quote request + a `status='sent'` PO from that supplier ⇒ ask the admin. Never classifies the reply's content. Deduped (one unread prompt per PO, not one per message).
- `PoReceiptPromptModal.tsx` + shared `PoReceiptForm.tsx` (also used by a plain "Confirm Receipt" button on any `sent` row in `PurchaseOrdersTab.tsx` for admin-initiated confirmation any time). Received qty defaults to ordered, editable per line. Confirming calls the existing `create_bill_entry` RPC via a new `confirmPoReceipt` service function (bypasses `BillEntryTab`'s narrower product|spare-only `PoItemInput` type, since a PO item can legitimately be a gift).
- Migration: `20260901130000_supplier_monthly_rfq_phase4.sql`.

## Key tables
`suppliers`, `supplier_products` (+`price_updated_at`), `purchase_orders`, `po_items`, `purchase_bills`, `purchase_quote_requests` (+`no_po_not_low_stock` resolution value), `purchase_quote_replies`, `purchase_quote_dismissals` (new), `approvals`, `notifications` (new types: `po_approval_pending`, `po_receipt_check_prompt`, `monthly_rfq_sent`).

## Key frontend files
`src/app/admin/purchase/` — `PurchaseOrdersTab.tsx`, `PurchaseQuotesTab.tsx`, `PoApprovalPromptModal.tsx`, `PoReceiptPromptModal.tsx`, `PoReceiptForm.tsx`. `src/app/admin/suppliers/SupplierItemsPanel.tsx`. `src/app/admin/masters/SettingsTab.tsx`. `src/app/admin/AdminShell.tsx` (mounts both popups).

## Key backend files
`supabase/functions/_shared/whatsapp-handle-message.ts` (`handleSupplierReply`, `notifyAboutPoReceiptCheck`), `supabase/functions/_shared/whatsapp-extract-quote-deterministic.ts`, `supabase/functions/wa-scheduled-tasks/index.ts` (`runMonthlyQuoteRequests`, `runResolveQuoteRequests`). Deployed to both `wasi-webhook` and `whatsapp-webhook` (both bundle the shared handler).

## Three pre-existing bugs found and fixed along the way (none introduced by this work)

1. **`listPoItems` used a PostgREST embedded join** (`select("*, products(name), spares(name)")`) on `po_items.item_id`, which has no real foreign key (polymorphic product|spare|gift) — this threw `PGRST200` and silently failed, meaning **the existing Purchase Orders tab's item-expand view had never actually shown anything**. Fixed with the same separate-lookups-merged-client-side pattern used elsewhere (`attachQuoteRequestItemNames`); fixed the existing tab for free.
2. **`approvals` and `purchase_orders` were never added to the `supabase_realtime` publication** — only `notifications` had been, for the bell. Both popups' cross-viewer auto-close depends on this; added via the same idempotent `alter publication ... add table` pattern already established for `notifications`.
3. **`create_bill_entry` had no guard against double-submission** — `update purchase_orders set status='received' where id=... and org_id=...` had no `status='sent'` condition, so two concurrent calls (a double-tap, or an accidental re-bill) would each fully re-run the inventory increment + expense insert. Fixed by claiming the PO first (`...and status='sent'`, checked via `FOUND`) before any side effect — verified with a real concurrent-call test.

One suspected fourth gap — role-broadcast `notifications` rows being unmarkable as read — was checked against the live DB before assuming, and turned out to already be fixed by `20260804190000_fix_notifications_mark_read_rls.sql` (which is actually more capable than what would have been written here: it also lets master clear the other role's copy). No action needed; noted so nobody re-"discovers" this.

## Admin-overridable WhatsApp copy (Automation → Templates)

Every outbound message this pipeline sends now renders through `_wa_render_template` (`whatsapp_templates` table) with a code-level fallback for when no override row exists — same contract, two different call shapes:
- **SQL-side callers** (`open_monthly_quote_requests`, the reactive `_auto_draft_purchase_order`) render at INSERT time and stash the result straight into `whatsapp_outbox.payload.body`. Template name: `po.quote_request` (shared by both the monthly and reactive triggers — same message purpose, each just has its own sensible fallback wording).
- **TS-side callers** that send synchronously via `sendMessage()` — `handleSupplierReply`'s receipt-check ack — use a new `renderWaTemplate()` helper in `whatsapp.ts` (2026-09-02) that calls the same `_wa_render_template` RPC directly. Template name: `po.receipt_check_ack`, `variable_map: {"1": "supplier_name"}`.

To reword either, add a row in Automation → Templates with that exact `name` — no code deploy needed. (An earlier version of this doc incorrectly said the monthly RFQ message was hardcoded — it was already using `po.quote_request` from Phase 2; only the receipt-check ack genuinely needed this fix.)

## What still needs a human's judgment, not just testing

- **The deterministic price-regex rules and its ₹1–₹1,00,00,000 sanity bounds are a self-authored heuristic**, unit-tested only against synthetic examples I wrote myself — never against a real supplier's actual WhatsApp reply history (Tanglish, Tamil-script numbers, unusual formats like "4.5k"). Watch the `quote_reply_needs_review` notifications for the first few real monthly cycles; if a lot of genuine prices are landing there instead of auto-parsing, the regex needs tuning against what suppliers actually send.
- **The low-stock gate and monthly order-qty basis assume suppliers restock the `warehouse` inventory location, not `van`** — this was my own reading of the business model (you don't order from a supplier into a technician's van), not something explicitly confirmed. Worth a quick sanity check if vans are ever restocked directly from suppliers.
- Minor, cosmetic: for a well-stocked item swept into the monthly batch, the RFQ's requested quantity often computes to "1" (the same `max_stock - stock_qty` formula reused from the reactive reorder trigger) — technically correct for price-comparison purposes, but a supplier receiving "please quote 1 unit" for something they know this business buys in bulk might find it an odd ask. Not wrong, just worth knowing if a supplier ever comments on it.
