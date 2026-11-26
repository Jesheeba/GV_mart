# Feature: date-display

Status: BUILT on feat/date-display (unpushed). Display-only, no migration. Helpers are English-only like the existing formatDate.ts helpers; the lead follow-up chip keeps its Tamil-aware formatIstDateTime.

## Purpose
Owner feedback (2026-11-26): dates should read continuously on one line instead of taking extra space. The inventory found about 20 spots:
- date-times wrapping in narrow columns;
- date and time on separate rows;
- device-timezone helpers instead of IST;
- 16 full-width date pickers.

## Decision
- **One line, never wraps:** dates and date-times get `whitespace-nowrap`.
- **One compact format** for lists, e.g. "6 Oct, 10:00 am". The year shows only when it isn't the current year. Full "06/10/2026" stays on invoices and print.
- **Merge split rows:** "Date / Slot / Visit time" and "Start / Close time" become one line ("Tue 6 Oct · 10:00–11:00 am").
- **IST everywhere:** replace `toLocaleString()`/`ddmmyyyy` device-timezone uses with the shared IST helpers.
- **Date pickers:** fixed `w-44` instead of full width.
- **Follow-up picker:** the persistent "will be set for…" helper is merged into the picker's own line.

## Architecture
- Add `formatShortDateTime` to `src/lib/formatDate.ts`, next to the existing helpers.
- Replace the ad-hoc formatters at the inventory locations (TicketsList, Tasks, FollowupBadges, TicketDetail, CustomerBookingDetail, TechnicianDetail, SegmentsTab, Accounts, CustomerOutstanding, InvoicePage, Appointments, Ops dashboard, Attendance, ReferralBonus, TaskWorkLog, SpareSelect).

## Impact map
- Display only.
- Invoice print format stays DD/MM/YYYY, but moves to IST. Previously it used the device timezone, which could show the wrong day near midnight. This is a bug fix.

## Edge cases
- Midnight IST vs UTC: covered by helper unit tests.
- Null dates: "—".
- Tamil locale: month names via the existing i18n locale.

## Acceptance criteria
1. No date or date-time wraps in the listed screens at 1280px.
2. Split date/time rows are one line.
3. No `toLocaleString()` without an IST timeZone remains in the listed files.
4. `formatShortDateTime` unit tests: same year vs other year, midnight IST, null.
