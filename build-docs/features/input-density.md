# Feature: input-density

Status: PLANNED, awaiting owner approval. No migration.

## Purpose
Owner feedback (2026-11-26): the app feels clumsy, and full-width boxes are used for 5-digit numbers. The inventory found about 72 short-number inputs across 44 pages that are full width or stretched, plus inconsistent select heights (h-8 / h-9 / h-10 / h-11).

## Decision
- **Fix width, not height.** Inputs stay 40px tall (good touch target on the technician and customer phones). Short values get a width that fits their content.
- **Width tokens** (one small map, reused everywhere): qty/% `w-20`, TDS/pH/reading/km `w-24`, pincode/OTP `w-28`, amount `w-32`, mobile `w-40`.
- **Group short fields in one row:** TDS + pH; pincode next to district; min/max qty; lifetime value + unit.
- **Number keypad on phones:** `inputMode="numeric"`/`"decimal"`, plus `maxLength` where the length is fixed (pincode 6, mobile 10, OTP 4–6).
- **One select height:** h-10 everywhere (the h-11 and h-8 outliers move to h-10).

## Phasing (most-used screens first)
- **B1:**
  - On-site visit (technician);
  - Admin customer form, Water household, Family members;
  - New lead, Edit lead, Lead detail fields;
  - Technician expenses, customer app Link phone.
- **B2:** technician new/detail, HR Add staff, expenses tabs, Accounts, Returns, PnL, Product lifecycle / enquiry config, and the remaining masters (including EntityCrudTable number fields).

## Architecture
- `src/lib/fieldWidth.ts`: `FIELD_W = { qty, reading, pincode, amount, mobile }` → class strings. Applied via `className` on the existing `Input`. No new component.
- No change to the `Input` primitive default, so pages not in scope are unaffected.

## Impact map
- Layout only, no data or API change.
- Risk: responsive breakpoints. Each touched form is checked at 390px (phone) and 1280px (desktop).
- Validation unchanged; `maxLength` matches existing zod length rules (checked per field).

## Edge cases
- Large amounts (₹10,00,000.00) still fit `w-32`. Checked.
- Tamil labels are longer than English; the label wraps, the input width is fixed.
- Paste of "+91 98xxx" into a mobile field with maxLength 10: existing normalisation must run before the cap. Checked per field.

## Acceptance criteria
1. No in-scope short-number input is full width on desktop.
2. Phones open the numeric keypad for those fields.
3. Every select is 40px tall.
4. At 390px nothing overflows horizontally, and at 1280px grouped fields share a row.
5. Existing validation tests still pass.
