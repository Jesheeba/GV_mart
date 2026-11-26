# Feature: choice-dropdowns-not-set (2026-11-26)

Status: SHIPPED 2026-11-26. Migration 20261229100000 applied live.

Open:
- About 15 pre-existing missing i18n keys (automation/customerApp/leads errors, e.g. `leads.detail.notePlaceholder`).

## Purpose
- Owner: every either/or data-entry choice in the app becomes a dropdown with a visible "Not set" option.
- This replaces the earlier "2–3 options = buttons" rule (choice-no-preselect.md).

## Rule
- One control everywhere: `components/shared/ChoiceSelect` (native `<select>`). The first option is always **"Not set"** (empty value).
- Nothing is pre-selected on a new record. Edit shows the saved value.
- What "Not set" does on Save depends on the field:
  - **A — saved as empty.** The column is already nullable and nothing downstream needs a value.
  - **B — address type/ownership.** Saved as empty after migration 20261229100000 (owner decision). Rehearsal passed 12/0; not applied.
  - **C — required.** "Not set" is shown, but Save is blocked with "Choose an option" because the record can't exist without a value (e.g. a payment needs a method).
- Empty values that already mean something real keep their label: "Any", "All sources", "Every day", "Default", "No gift", "None", "No role".
- A dropdown pre-filled by a master rule is not a default and stays pre-filled (lead outcome → follow-up type / follow-up needed / lost-reason hint).

## Scope (from the 2026-11-26 inventory; file:line in the agent report)
| Area | Fields | Class |
|---|---|---|
| Customer | address type, ownership (done); water source (done); member relation; on-site water source, tank cleaned, product explained | B / A |
| Money | payment method (new sale, record payment, rent out, sell AMC, on-site); bill-entry expense category; log-expense category (Accounts, P&L) | C |
| Leads | source; product category / kind ("All" → "Not set"); follow-up type (set, bulk, log, outcome default); channel; outcome; follow-up needed?; lost reason; post-service outcome | C / A |
| Service | complaint priority; availability reason; enquiry generated?; enquiry type (pre-selected "online" today) | C / A |
| Tasks | priority | C |
| HR / expenses | staff role, availability status, tier override, bike ownership, adjustment target and type | C |
| Purchase / masters | supplier item type, PO item type, attribute data type and boolean value, related type, lifetime and interval unit, doc type, every EntityCrudTable select, ReorderableListCard selects (pre-select the first option today) | C |
| Automation | bot phrase category, segment rule selects, flow trigger/action, template category, video topic | C |

## Owner decisions (2026-11-26)
- Q1 lead source, follow-up type, complaint priority, task priority: "Not set" is shown and Save is blocked until a value is chosen (class C). No DB change.
- Q2 GST Extra/Included: keeps the org-setting default (unchanged).

## Out of scope
- Not data entry: filters, tabs, period and view switches, the language toggle, pure UI modes (password generate/type, equipment mode, discount yes/no gate, percent/amount), immediate action buttons, record pickers, checkboxes.
- Campaigns (being removed, memory 2026-11-12).
- GST Extra/Included (Q2).

## Architecture
- `ChoiceSelect`: always renders "Not set" first; `required` only changes validation, not the option.
- Forms keep their zod rules: C fields stay required (existing `chooseOption`/`*Required` messages); A fields optional.
- `EntityCrudTable` and `ReorderableListCard`: the placeholder becomes "Not set" (label change only). Required unless the field is optional. ReorderableListCard stops pre-selecting the first option.
- No DB change beyond 20261229100000.

## Impact map
- About 35 component files plus their zod schemas, ChoiceSelect, EntityCrudTable, ReorderableListCard, i18n en/ta.
- Offline outbox (technician on-site): payloads unchanged. Validation is client-side, so nothing new is needed offline.
- On-site payment method: pre-selected "cash" today, with a known open bug (the invoice is queued before the payment step). The control changes, but the bug fix is out of scope and recorded as open.

## Edge cases
- Dynamic option lists still loading: stay on "Not set" and never jump to the first option.
- A saved value no longer in the master list: show it as "Not set" and keep it unless changed (no silent overwrite). Covered by a test.
- Tier override with `tier_id` null: shows "Not set" instead of a blank select.

## Acceptance criteria
1. Every in-scope field is a dropdown whose first option is "Not set", with nothing pre-selected on new records.
2. A fields save "Not set" as empty. C fields block Save with an inline error and focus the field.
3. Edit shows the saved value. Changing an A field to "Not set" clears it.
4. Out-of-scope controls are unchanged.
5. tsc clean, unit tests pass, and a test exists per changed schema/default.
