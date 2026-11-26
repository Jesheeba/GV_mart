# Feature: customer-data-sync (sweep fixes, 2026-11-26)

Owner: "fix them all". These came from a code sweep for the same class of bug as the duplicate Water & household section: one concept shown or stored twice, or create-only state used in edit.

## Fixes
1. **Primary member ↔ customer row.** `customers.name/mobile/email/profession` copy the primary member, but only `set_primary_member` refreshed them. Fix: trigger pair `zz_sync_primary_member_to_customer` / `zz_sync_customer_to_primary_member` (migration `20261215120000`).
   - Each side copies only the columns changed in that statement, so an unrelated edit never blanks the other side.
   - A customer editing their own member row moves only name/profession; mobile/email are used for sign-in matching and stay staff-only.
   - `updateMember`'s client-side profession copy is removed (single mechanism).
2. **Email in two boxes.** Create and edit had an account-email box plus the primary member's email; each saved somewhere different. Now the primary member's row is the one box. Create copies it to `customers.email`; the trigger keeps them in step.
   - One-off backfill fills blank member emails from the account email.
   - It deliberately never fills `customers.email` from a member email, because that would newly enable Google sign-in matching.
3. **Customer-app address overwritten by admin save.** The app writes `full_address + area`. The admin form treated area alone as "structured", dropped `full_address`, and Save rebuilt it from the bare area. Fix:
   - `hasStreetLevelFields` / `resolveFullAddress` in `src/lib/address.ts`.
   - Trigger `clear_stale_address_parts`: when the customer changes their address text, an admin's old street-level parts are cleared.
4. **Profession reverted.** The member edit form now prefers the customer row's profession for the primary member, and the trigger syncs both ways.
5. **Moved-out members counted.** Fixed in the admin customer list (`member_count`), the technician job/history, and the customer app.
6. **Drafts.** New Complaint draft now keeps `complaintTypeId` + `referredByTechnicianId`. New Sale draft keeps `referredByTechnicianId`. Older drafts restore fine (fields optional).
7. **Lead fields card.** The edit form re-reads the lead on every Edit, and the card is keyed by lead id. Cancelled or previous-lead values no longer leak in.

## Not fixed (needs a product decision)
- `EditLeadDialog.tsx` is unused: a lead's name/mobile/source/product type/notes can't be edited after creation. Building that edit flow is a new feature, not a mismatch fix.
- Existing rows whose primary member and customer row already disagree on name/mobile are left as-is. Which side is newer can't be known; count them at apply time.

## Acceptance criteria
- Edit primary member name/mobile/email (staff): header, list, call button and technician view show the new values.
- One email input per person, in create and edit.
- Customer edits the address text in the app, then admin opens edit and saves without changes: the customer's text survives.
- Moved-out member: excluded from every count.
- Restore a complaint/sale draft: complaint type link and referrer are back.
