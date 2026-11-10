# Feature: Six lead summary tiles

## Purpose
Show Total / New / Contacted / Quotation / Won / Lost as count+% tiles, replacing the current 4-tile inline stats block on `LeadsPage.tsx`.

## Architecture
- No migration — pure client-side aggregation over the already-fetched/filtered lead list (same source as today's `stats` `useMemo`, lines ~70-81), extended to all 5 `lead_status` values + total.
- Formula: `pct(status) = round(count(status) / total * 100)`; `Total` tile shows `100%` when `total > 0`, else `0%`.
- Decide once, document: tiles reflect the **currently filtered** list (consistent with existing 4-tile behavior) — not global unfiltered counts. Label stays accurate either way since this matches current behavior, no user-facing change in meaning.
- Map DB status values to tile labels: `new→New, contacted→Contacted, quoted→Quotation, won→Won, lost→Lost`.

## Impact map
- `LeadsPage.tsx` — replace 4-tile block with 6-tile grid (reuse `.metric`/`.numbers` layout from prototype, adapted to existing design tokens).
- No other feature reads this `stats` memo today (confirmed: it's local to `LeadsPage.tsx`).

## Edge cases
- Zero leads total → all tiles show `0` / `0%` except Total which is `0%` per spec's explicit zero-case rule.
- Filtered-to-empty state → tiles all zero while table shows empty state; not a bug, expected.

## Acceptance criteria
- [ ] Six tiles appear in order: Total, New, Contacted, Quotation, Won, Lost.
- [ ] Every tile shows a count and a percentage.
- [ ] Total shows 100% when leads exist, 0% when none.
- [ ] Percentages use the same filtered dataset as the counts.
- [ ] Tiles are screen-reader accessible (`aria-label` per tile, e.g. "New: 20 leads, 20 percent").
- [ ] Responsive: 6 tiles desktop, collapses to fewer columns on mobile (per prototype's `@media` breakpoints).
