# Fix: onsite-payment-method

Status: BUILT on fix/onsite-payment-method, awaiting owner review. No migration.

## Purpose
Two bugs in the technician on-site visit (found during the UX pass, 2026-11-26):
1. The invoice is queued on the **invoice** step, but the method was only chosen later on the **payment** step. So every on-site invoice recorded the default "cash", and no transfer reference.
2. UPI is offered when online payments are on, but `servicePaymentSchema` only accepted cash/transfer, so a UPI visit could never be completed.

## Change
- The method picker (plus the QR and transfer reference/description) moved to the invoice step. It starts **unselected** and is **required** before "Create invoice" when the total is above 0. For transfer, the reference and description are required (existing rule).
- Free / ₹0 jobs: no method is asked and cash is recorded, as before.
- Payment step: shows the chosen method read-only ("set on the invoice; ask the office to correct it"). UPI collection, proof upload and OTP are unchanged.
- `servicePaymentSchema` accepts `upi`.
- Draft restore: a saved method is restored only once the invoice is queued. Older drafts stored the old "cash" default before anyone chose.
- Server (`create_service_invoice`) is unchanged; it already stores whatever method and reference it is sent.

## Impact map
- `OnSiteVisitPage.tsx` (invoice + payment steps, draft restore/reset), `lib/validation/technician.ts`, en/ta strings.
- Offline outbox payload shape unchanged (`service_invoice.create`).
- UPI path unchanged after the invoice (amountPaid 0, then QR collect → proof → OTP).

## Acceptance criteria
1. On a chargeable job with a total above 0, nothing is selected and "Create invoice" shows "Choose how the customer is paying" until a method is picked.
2. The invoice records the method picked (and the transfer reference).
3. A UPI visit passes the payment check and can finish.
4. ₹0 jobs create the invoice without asking for a method.
5. The payment step cannot change the method after the invoice exists.
