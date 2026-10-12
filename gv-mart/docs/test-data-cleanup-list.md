# Test-data cleanup list (real organisation) — maintained list, nothing here has been deleted

Status 2026-10-15: **list only**. Deleting any of this needs a separate approval. The AMC contract below is the only row
touched (cancelled, not deleted — see "Cancelled, not deleted").

## 8 Oct referral / AMC test rows
| Kind | Count | How to find them | Notes |
|---|---|---|---|
| Referral leads | 3 | `leads` with `source='referral'`, created 2026-10-08 (sale, service, AMC) | owner = the referring technician |
| Invoice | 1 | `invoices` created 2026-10-08 | the walk-in sale referral |
| Service tickets | 7 | `service_tickets` created 2026-10-08 | 1 service + 6 AMC visit tickets |
| AMC contract | 1 | id `711677e3-2d49-43c0-81bd-c59162076ee7`, plan Silver, start 2026-10-08 | **cancelled** (see below) |
| Customers | those of the above | the customers linked from the leads/invoice/tickets | not flagged, not deleted |

## Cancelled, not deleted
* AMC contract `711677e3-…` → `cancel_amc_contract(…, reason)`: row kept, `cancelled_at` set, status `expired`; its
  open/assigned visit tickets cancelled and both technicians freed. History, invoice link and referral lead untouched.
* Pre-change JSON backup: `Desktop\GV_mart_db_backup_2026-10-15_items_1_5\amc_contract_8oct.json` (contract, 6 tickets,
  6 appointments, 29 notifications) plus `functions_before.sql` (34 live function definitions) and `index_before.sql`.

## Permanent flagged test record (kept on purpose)
* Customer **"jeshee test trigger"** (Sirah Digital, Pallavaram, the test mobile) — flagged `is_test = true`. The lead that
  shares the number is flagged automatically by the sync trigger. Supplier "PVM" shares the number and is **not** changed.
* Until the flag is verified live: no invoices, tickets or AMC are created for it.

## Open
* Whether the 8 Oct rows should be deleted after the audit (user decides).
