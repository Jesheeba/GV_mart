# Feature: "Frequently used" pinned section in the admin sidebar

## Purpose
The admin sidebar has 25+ items across 7 groups, so the pages a person uses daily are often far down the list. They can pin any item to a "Frequently used" section at the top, just below Dashboard.

## Architecture
- **Pins are manual, not auto-tracked.** The user asked to "pin", so nothing is ranked by usage. The section is named "Frequently used" (`navGroups.pinned`).
- **Storage:** `localStorage` key `gv_mart_admin_sidebar_pins:<profile.id>`, holding a JSON array of nav `key`s in the order they were pinned. Same pattern as the existing `gv_mart_admin_sidebar_collapsed`. No DB, migration or RLS. Pins are per user and per browser/device.
- **Pure helpers in `nav.ts`** (unit-testable):
  - `parsePinnedKeys(raw: string | null): string[]` handles invalid JSON, non-arrays, non-strings and duplicates, returning `[]` or a cleaned list.
  - `resolvePinnedItems(keys, items)` returns the visible pinned items in pin order. It drops keys that are unknown, not allowed for the role, or equal to `dashboard`.
- **AdminShell:**
  - It holds `pinnedKeys` state, loaded once the profile is ready and saved on change inside try/catch, the same way as the collapsed key.
  - The section renders between Dashboard and the first group, and only when it has at least one item.
  - Pinned items **also stay in their original group**, so nothing moves from where people expect it.
- **Pin control:**
  - A small pin/unpin icon button sits beside each nav link (as a sibling, not nested inside the `<a>`). It shows on hover and on focus-within.
  - It is shown only when the sidebar is expanded. In collapsed mode the pinned items still render at the top, with a divider.
  - `aria-label`: "Pin to Frequently used" or "Unpin from Frequently used". `aria-pressed` reflects the state.

## Impact map
- `gv-mart/src/app/admin/nav.ts`: adds 2 pure helpers. The existing `groupNavSections` is unchanged.
- `gv-mart/src/app/admin/AdminShell.tsx`:
  - adds pin state and the new section
  - wraps `renderNavLink` output so the pin button can sit next to the link.
  - **Risk:** the badges (myDay, leaveRequests, customerOutstanding) and the collapsed-tooltip logic must keep working, including on the duplicate pinned copy.
- `gv-mart/src/lib/i18n/en.json` and `ta.json`: add `navGroups.pinned`, `shell.pinItem` and `shell.unpinItem`.
- `gv-mart/src/app/admin/nav.test.ts`: adds tests for the helpers.
- No routes, roles, DB tables or other features are touched.

## Edge cases and failure modes
- **Corrupt or tampered localStorage value:** it is ignored and treated as `[]`, so the page never crashes.
- **localStorage blocked** (private mode): pinning still works for the session, it just isn't saved.
- **Role changes or an item is removed from `ADMIN_NAV`:** the stale key is hidden, not shown as a broken link.
- **A different user logs in on the same browser:** their pins are separate because the key includes the profile id.
- **The same item is pinned twice** (e.g. from two tabs): duplicates are removed when the value is parsed.
- **Security:** the stored data is only nav keys that are matched against `ADMIN_NAV`. It is never used as a path or as HTML, so there is no injection path, and role filtering still applies.

## Acceptance criteria
- [ ] Every non-Dashboard sidebar item has a keyboard-reachable pin button when the sidebar is expanded.
- [ ] Pinning adds the item to "Frequently used" below Dashboard, and unpinning removes it. The section is hidden when empty.
- [ ] Pins survive a reload and are kept per user.
- [ ] Pinned items keep their badges and their active highlight.
- [ ] Collapsed sidebar: the pinned items show at the top, and the tooltip still works.
- [ ] Invalid stored JSON, unknown keys and keys for other roles are ignored.
- [ ] Labels are translated in English and Tamil.
