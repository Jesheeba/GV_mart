# Technician table (batch-17 item 15)

Status: BUILT on `feat/technician-table`, NOT applied (migration `20261030100000_technician_table`). Cut from origin/main.
Definitions are the owner's of 2026-10-15.

## What the master and operations see
Technicians list page, under the existing table: **Technician performance (invoice basis)** for the period chosen at the top.
One row per technician: jobs, revenue, average call value, app rating, working days, present, leave, absent, referral revenue
(service / sales / AMC / total). Masters has a new **Holidays** card (date + name; empty means no holidays).

## Definitions
| Column | Rule |
|---|---|
| Revenue | `invoices.total` of COMPLETED jobs. A completed ticket's invoice goes to the technician of the ticket's last finished visit, in the period that visit ended (IST). Test customers excluded. Not `service_charge`, not "collected". |
| Average call value | revenue / completed jobs that have an invoice. |
| Working days | Monday to Saturday from max(period start, the day the technician record was created) to min(period end, today IST), minus holidays. |
| Absent | working days minus working days with an attendance check-in or a `leave` row in `technician_availability`. A day both present and on leave counts once. |
| Google reviews | none, anywhere in this table. The rating shown is the customer-app rating. |
| Referral revenue | invoice totals stamped to the technician, FORWARD-ONLY: split service (the invoice belongs to a ticket), AMC (type amc), sales (the rest). |

## Referral stamp (the one design decision, for the owner)
Invoices had no referrer. New nullable `invoices.referred_by_technician_id`, set by a BEFORE INSERT trigger from the customer's
technician-originated lead: source `referral` or `field`, `owner_id` a technician of the org, not lost, not a test lead, created within
the last 30 days (the app's own open-lead window). Most recent wins. A walk-in sale with a referring technician mints such a lead in
the same transaction, so it is stamped immediately. No back-fill, no UPDATE path, and the trigger never blocks an invoice.
To change: the window or the source list is one line in `_trg_invoice_stamp_referral`.

## Not changed
`create_sale`, `sell_amc_plan*`, `report_performance`, `technician_kpi_summary`, incentives and pay. The older Revenue column and the
new one differ by design and the screen says so.

## Estimate
Built: DB 0.75 day, screen and Masters card 0.5, tests and wrapper 0.5 = **1.75 days**. Remaining: rehearsal and fixes 0.25,
owner review of the referral rule 0.25, browser pass 0.25.

## Risks
Attribution of an invoice to the last visit's technician when a ticket had several visits (stated above). Technician records created
late make earlier days uncounted (stated on screen). `report_technician_table` is registered in the test-customer guard manifest.
