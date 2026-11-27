# Quotation edit + ₹ discount + lead link (2026-11-27)

Status: BUILT on branch feat/quotation-edit-discount (owner approved 2026-11-27). Migration 20270103100000 APPLIED LIVE 2026-11-27 (rehearsal 21/21). Exact ₹ discount fix (step 5) not included.

## Purpose
- A direct quotation (no lead) never reaches Leads / Daily Follow Up, so it can go cold unseen.
- Quotation Edit only changes valid-until (decision 2026-09-16, "minor fields only"). Owner now wants items, qty and amount editable. **This reverses that decision.**
- Convert-to-sale re-prices from today's master price, so the customer can be billed differently from the quote.

## Owner decisions (2026-11-27)
- D1 Direct quotation → always create a **new lead** from the customer (owner chose "new lead", not "link an existing open lead").
- D2 Lower amount = **discount in ₹** with an on/off switch (like the sale's opt-in discount) + required reason. Not a per-line price override.
- D3 Convert to sale uses the **quoted** prices, qty and discount.
- D4 Edit only while **Open**; Converted/Lost locked; every edit kept in history (old → new total, who, when, reason).

## Architecture
DB (one migration + rollback):
- `quotations`: `+ discount_amount numeric(12,2) not null default 0 check (>= 0)`, `+ discount_reason text`.
- New `quotation_revisions` (org_id, quotation_id, edited_by, edited_at, old_total, new_total, old_discount, new_discount, reason, items_before jsonb, items_after jsonb). RLS: same staff read as quotations; insert only via RPC.
- `create_quotation`: new `p_discount_amount`, `p_discount_reason`. When `p_lead_id` is null → insert a lead from the customer (name, mobile, source "Direct quotation", status quoted; leads.owner_id is a technician FK so it stays null, and the lead is assigned to the creator via assign_lead, best-effort) and set `quotations.lead_id`. Also logs `quotation_created` and books a follow-up call 2 days out (Daily Follow Up lists follow-ups, not bare leads); a refused follow-up is a warning, never blocks the quote.
- New `update_quotation(p_id, p_items, p_discount_amount, p_discount_reason, p_valid_until, p_reason)`: refuses unless status = open (row locked `for update`); re-prices lines from master; writes a revision row; recomputes total.
- `create_sale` / `_sale_create_line_invoice`: when `p_quotation_id` is given, price each line from `quotation_items.price` instead of the master.
- Discount cap: `discount_amount <= subtotal × settings.discount_admin_max / 100` checked in both quotation RPCs, so a quote can't promise what the sale would reject.

UI:
- Quotation form + Edit (popup): item lines with qty, Discount switch → ₹ amount + reason (required when > 0), live "Subtotal − Discount = Total". The existing Edit (valid-until only) is replaced.
- Detail page: discount line + "Edit history" list.
- New Sale from quotation: discount switch on and ₹ amount prefilled from the quote; lines show quoted prices.
- KPI % in corners: already built (5fa3e6b, separate branch).

## Impact map
- `create_sale`: the most-shared RPC. Parallel sessions have overwritten each other's versions before (memory: parallel migration collisions). The migration must be rebuilt from the live body, compared by md5 before applying.
- `_sale_create_line_invoice`: also used for non-quotation sales. The new branch only runs when a quotation id is passed.
- Leads: auto-created leads raise lead counts and lead KPIs and show in Daily Follow Up. The round-robin switch is OFF, so assigning to the creator is unaffected.
- Accounts/Reports: none changed. They read `invoices.discount`, which the sale already fills.
- `listQuotations`/`getQuotation` and hand-patched `database.ts` types: add the new columns.
- Lead detail quotations list: unchanged.
- Lock trigger also covers direct table writes (staff RLS allows them), so Converted/Lost really can't change.
- Rollout order: apply the migration FIRST, then merge the UI. Old UI on the new DB still works (new params have defaults).

## Edge cases
- Quote edited in two tabs at once: `for update` lock, so the second save sees the latest version.
- Edit after it's converted or lost: the RPC refuses, and the UI hides Edit.
- Discount > subtotal or > cap: blocked in the UI and in the RPC.
- Product deactivated after quoting: converting still uses the quoted price. The sale picker today only allows active items. The quoted item still converts, with a warning.
- Customer has no mobile: lead created with the customer's name only. If the customer already has an open lead, a duplicate lead is created (that follows D1; flagged).
- ₹ discount → sale: the sale sends a % rounded to 2 decimals, so a ₹ amount can land up to ~₹1 off (this already happens in today's sale ₹ discount). Fixing it exactly needs `create_sale` to accept an amount. Proposed as optional step 5.
- Old quotes: discount_amount = 0, behaviour unchanged.

## Acceptance criteria
1. Saving a direct quotation creates a lead with status Quoted, linked on the quote, and it shows in Leads.
2. An Open quote can change items, qty, ₹ discount (switch) + reason. The total updates and a history row records old → new.
3. Converted and Lost quotes show no Edit, and the RPC refuses an edit.
4. Discount above the cap is blocked with a message, in both the UI and the RPC.
5. Convert-to-sale bills the quoted unit prices even after a master price change, and the invoice discount equals the quote's discount (±₹1).
6. Accounts/Reports show the reduced amount, through the existing invoice discount.

## Build order
1. Migration + rollback (text only, no apply until owner names it) + SQL tests in a rolled-back transaction.
2. Service/types + quotation form discount + Edit popup + history.
3. Sale conversion prefill.
4. Direct-quote → lead.
5. (optional) exact ₹ discount in `create_sale`.
