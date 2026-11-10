# Feature: Lead category chips & filter cleanup

## Purpose
Replace the hidden "Lead type" select and the "All topics" filter with a visible category chip bar, and stop mislabeling the assignment filter as generic "All leads".

## Architecture
- No migration — reuses existing `leads.kind`/`kind_key` (`lead_kind` enum: service/spare/product/amc) and `useLeadKindOptions`.
- UI: `LeadsPage.tsx` — remove `enquiryType` select (lines ~48, 204-209) and the `kind` select (lines ~49, 216-228); add a `<div class="chips">`-style button group bound to the same `kind` filter state, ordered Service → Product → Spare → AMC, plus "All leads" reset (active = clears `kind`). Visually emphasize "Product" (first after All, or distinct styling) per spec.
- `enquiry_type` column/data is untouched — only its dedicated filter UI is removed.

## Impact map
- `LeadsPage.tsx` — filter state (`enquiryType` filter removed from UI, `kind` filter now chip-driven), list query unaffected (same `kind`/`kind_key` predicate).
- `LeadsKanban.tsx` — check it doesn't also render the removed selects.
- i18n: remove unused `leads.filters.allTopics` usage if no longer referenced elsewhere; keep `leads.filters.allKinds` key reused for the "All leads" chip.
- No API/DB/other-feature impact.

## Edge cases
- No leads in a category → chip shows but list renders empty state (existing empty-state component).
- Deep-link / saved filter URLs that reference the old `enquiryType` query param → safe to drop silently (no evidence of persisted/shared URLs with this param).

## Acceptance criteria
- [ ] Category chips render in order: All leads, Service, Product, Spare, AMC.
- [ ] Selecting a chip filters the list via existing `kind` predicate; selected chip shows active state (`aria-pressed` or equivalent for screen readers).
- [ ] "All topics" filter no longer appears anywhere on the page.
- [ ] Separate "Lead type" dropdown no longer appears.
- [ ] Existing assignment filter (`assignedFilter`) still works, unchanged in behavior.
