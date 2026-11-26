# picker-search (F1)

**Purpose:** type-to-search spares and products in billing pickers; multi-word queries; no repeated label text.

**Architecture**
- `src/lib/productSearch.ts`: `matchesTokens(haystack, query)` — every whitespace token must appear (any order). `productMatchesQuery` uses it. New `spareMatchesQuery`.
- `productSearchLabel`: drop model/brand parts already contained in the product name; drop a brand whose name ends "(spreadsheet import)".
- `ItemsStep.tsx` spare `<select>` → existing `Autocomplete` (same as products), label shows price + stock.
- Same swap in `QuotationFormPage.tsx` / `PoItemRows.tsx` where spares are still `<select>`.

**Impact map:** ItemsStep (New Sale), QuotationFormPage, PoItemRows — all consumers of productSearch.ts. No DB, no RPC, no service change. Risk: Autocomplete inside Card overflow — already portalled.

**Edge cases:** empty query → full list on focus (openOnFocus); extra spaces/tabs; punctuation (`10"`, `H1/4`); case; archived items excluded; 0 matches → "No data"; keyboard Arrow/Enter/Esc; clearing text resets selection.

**Acceptance**
- A1 Typing "ros adapter 24v" lists both ACCORD 24V adapters.
- A2 "rop blue" finds ROP 2090 BLUE and ROP ROMA BLUE.
- A3 Label for ROP 2090 BLUE reads "ROP 2090 BLUE" (no repeat, no "spreadsheet import").
- A4 Real brand/model products still show "Kent Grand — RO Name".
- A5 Space key types a space in the spare search box.
