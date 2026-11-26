# Feature: choice-no-preselect

Status: BUILT on feat/choice-no-preselect (2026-11-26), not merged. No migration. OnSiteVisitPage payment method deliberately left at its default — see report (invoice is created before the payment step).

## Purpose
Owner feedback (2026-11-26): either/or fields open with an option already chosen (e.g. Residential, Own, Cash), so staff save without deciding. About 49 such controls exist (inventory 2026-11-26).

## Decision (owner approved my recommendation over "make them all dropdowns")
- **Update 2026-11-26 (owner override):** customer Address type, Ownership and Water source are dropdowns (`ChoiceSelect`), still with nothing pre-selected. The rest below still applies to other fields.
- The real bug is the **pre-selection**, not the control type.
- **2–3 options:** keep one-tap buttons with **nothing selected**. Save is blocked with "Choose Residential or Commercial".
- **4+ options:** dropdown starting at "Select…", required.
- **Optional fields:** "Not set" option, saved as empty.
- **Existing records:** untouched. Edit forms show the saved value.
- **Keep a default** only where it's a UI mode or a safe neutral value, not data about a customer or money:
  - password generate/type;
  - complaint equipment mode, product-editor mode;
  - bulk follow-up spread/same, log-interaction mode;
  - outstanding reminder/task, on-site discount percent/amount;
  - priority "Normal";
  - is_active "Active", auto-assign ON.

## Scope: changes (from inventory)
| Group | Fields |
|---|---|
| Customer address | address type, ownership: admin form (buttons) + customer app `AddressForm` (select → buttons, one control everywhere) |
| Money | payment method in New Sale, Record payment, Rent out, technician Sell AMC, On-site visit |
| Follow-ups | type in Set follow-up / Bulk follow-up / Log interaction, channel in Log interaction |
| Service | confirmed-availability reason (ticket detail) |
| HR / expenses | Add staff role, technician availability status, bike ownership, adjustment target + type |
| Purchase / masters | supplier item type, PO item type, lifecycle unit, attribute data type, related-product type, media doc type (also fixes the UI "brochure" vs DB "other" mismatch) |
| All master add-forms | `EntityCrudTable` "select defaults to first option" rule → "Select…" placeholder + required (about 13 fields) |

## Architecture
- `SegButton` already takes `active: boolean`, so "nothing selected" is just state `T | null`. No new component.
- zod schemas: drop `.default()` and use `z.enum([...], { message })`. Form state starts `null`/`""`.
- `EntityCrudTable.openAddForm`: start select fields at `""`, render `<option value="" disabled>Select…</option>`, and block submit while empty unless the field is marked `optional`. (Its old "first option" rule existed only because an untouched select showed one value and submitted another; a visible placeholder fixes that properly.)
- Error message under the group, focus moves to the first missing choice (accessibility).

## Impact map
| Touches | Risk |
|---|---|
| `CustomerFormPage`, `AddressForm` (customer app + Book Service picker) | Save path must still send a value. The RPC's `coalesce(...,'residential')` stays as a safety net for system-created addresses (WhatsApp auto-onboard). |
| Payment dialogs / NewSale / OnSiteVisit / SellAmc / RentOut | A cash/transfer total changes only if staff pick differently. Offline outbox payloads unchanged (still a value at submit). |
| `EntityCrudTable` | Shared by about 15 master tabs. Edit mode must keep the existing value. |
| Validation tests (`lib/validation/*.test.ts`) | Schemas that had defaults; tests updated to expect "required". |

## Edge cases
- Edit an old record: shows its saved value, never blank.
- Technician offline on-site: validation is client-side, no network needed.
- Customer app: one-tap buttons stay thumb-friendly (40px+ targets).
- A select whose option list loads late: stays at "Select…", never jumps to the first option.

## Acceptance criteria
1. Every "change" field above opens with nothing selected on a new record.
2. Saving without choosing shows an inline error and doesn't submit.
3. Editing an existing record shows its saved choice.
4. Address type and ownership look and work the same in the admin form and the customer app.
5. Master add-forms show "Select…" and require a choice. Edit keeps the value.
6. Fields in the "keep default" list are unchanged.
