# Arrival Location Mismatch Alerts

## Purpose
`technician_arrival_blocks` already records every time a technician is stuck
>5 min outside the arrival geofence for a job (`MapPage.tsx`'s arrival state
machine, migration `20260915170000`). Today that row is write-only — nothing
reads it, so a wrong/stale customer pin never surfaces to anyone and stays
wrong indefinitely. This feature makes it visible: one task + one
notification per affected customer, reusing the exact pattern
`20261204140000_customer_needs_review_notify.sql` already established.

## Architecture
- **DB trigger** `technician_arrival_blocks_notify` (AFTER INSERT) →
  `_notify_arrival_block()`:
  - Looks up the block's `ticket_id` → `service_tickets.customer_id` /
    `address_id` → customer name + address text for a readable message.
  - Dedup: skip if an open task already exists for this customer
    (`ref_type = 'arrival_location_mismatch'`, `ref_id = customer_id`) — one
    open item per customer, not one per failed visit.
  - Flood cap: ≥20 such blocks org-wide in the last minute → one summary
    task/notification instead of one per row (same cap as the needs-review
    trigger).
  - Assigns the task to the oldest active `operation_admin` (fallback:
    oldest active `master`, matching `_sync_outstanding_tasks_for_org`'s
    fallback shape); notification broadcasts to role `operation_admin`
    (matches `submit_rating`'s low-rating notification target — this is a
    service-ops concern, not accounts/sales).
  - Wrapped in its own `BEGIN/EXCEPTION`, `RAISE WARNING` on failure — never
    blocks the original insert into `technician_arrival_blocks`.
- **UI**: `TaskDetailDialog.tsx` gets a small block for this `ref_type`
  (mirrors the existing `isCustomerNeedsReviewTask` block) — a "View
  customer" button that navigates to `/admin/customers/{ref_id}` so staff
  can immediately open the map picker and drop a corrected pin.
- **i18n**: label for the notification "type" badge in `NotificationsPage`.

## Impact map
- `technician_arrival_blocks` — unchanged schema, new trigger only.
- `tasks`, `notifications` — new rows, existing tables/RLS, no schema change.
- `TaskDetailDialog.tsx` — additive UI block, no existing behavior changed.
- Nothing customer-facing; no WhatsApp/SMS; no money tables touched.

## Edge cases / failure modes
- No active `operation_admin` or `master` in the org → task insert skipped
  (same as the needs-review trigger), notification still sent so nobody is
  silently unaware.
- Repeated blocks for the same still-unfixed address → deduped to one open
  task; once staff mark it done and a new block occurs later, a fresh task
  is created (not re-opened — avoids reviving a task that may have been
  closed for a good reason, e.g. customer address genuinely doesn't exist).
- Flood (≥20/min) → one summary item, not hundreds.
- Trigger failure of any kind → caught, logged via `RAISE WARNING`, original
  insert still succeeds.

## Acceptance criteria
- A `technician_arrival_blocks` insert creates exactly one open task
  (`ref_type = 'arrival_location_mismatch'`) and one `notifications` row,
  both referencing the ticket's customer, unless one is already open for
  that customer.
- A second block for the same customer while the task is still open creates
  no duplicate task/notification.
- 20+ blocks for the org within one minute collapse into a single summary
  task/notification.
- `TaskDetailDialog` shows a "View customer" button for this task type that
  navigates to the right customer.
- No existing test regresses; `technician_arrival_blocks` insert still
  succeeds even if the trigger function is made to fail (rehearsed the same
  way `customer_needs_review_notify` was).
