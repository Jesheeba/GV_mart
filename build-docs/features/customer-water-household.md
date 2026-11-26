# Feature: customer-water-household (one Water & household section)

## Purpose
- Edit customer showed "Water & household" twice: step 1 had `WaterHouseholdPanel` (customers row), and step 3 had a separate form (addresses row).
- Two stores for one concept. Create wrote `addresses.water_*` and edit step 3 also read it, but the detail page, technician job/history and customer app read `customers.water_*`. Water data entered at create was never shown anywhere.
- "Family members" count appeared inside Water & household. On edit it read the create-only field array and always showed 0. The Family section already shows the real count.
- Owner asked for: total hardness, "problems faced by the family" (list, + add another), and health condition removed (dropped from the DB).

## Decisions (owner, 2026-11-26)
- Keep the **customers** copy (every reader already uses it). Drop `addresses.water_source/water_tds/water_ph/health_condition` after copying values into empty customer fields.
- Problems faced: **visible to all** (plain `customers.household_problems text[]`), not the protected health table.
- Health condition: **drop from DB**: `customer_health_profile`, `get_customer_health_condition`, `household_health_level`, `settings.show_health_condition_to_technicians`.
- Family count: removed from Water & household everywhere (admin, technician, customer app); it stays in the Family section only.
- Editing stays master + sales_admin in the UI (customer routes are `SALES_ROLES`). The DB guard still also allows operation_admin, unchanged.

## Architecture
- Migration `20261213100000_customer_water_household_v2.sql`: adds `customers.water_hardness_ppm numeric(7,2) >= 0` and `household_problems text[] not null default '{}'` (≤10 items, no blanks); backfills from the primary address; drops the address columns and the health objects; extends `guard_water_profile_edit_roles` to the new columns.
- UI: `WaterHouseholdFields` (editable, shared by form step 3 and detail panel) and `components/shared/WaterHouseholdSummary` (read-only, shared by admin, technician and customer app).
- Form: steps People → Address → Water in both modes. Water step uses its own `waterForm`. Save writes the customers row (create: follow-up write after the RPC; edit: only when dirty).

## Impact map
- `CustomerFormPage`, `CustomerDetailPage`, `WaterHouseholdPanel`, `JobDetailPage`, `HistoryDetailPage`, `CustomerProfilePage`.
- `services/customers.ts` (getCustomer, updateCustomerWaterProfile, upsertPrimaryAddress, setAddressWaterHousehold removed), `services/customerApp.ts` (moved-out members filtered), `services/technician.ts` (select adds 2 columns; health RPC removed).
- `types/database.ts` (hand-patched), i18n en/ta.
- Risk: the technician job select falls back to no-water columns if the migration isn't applied yet. Deploy order: **migration first, then app**.

## Edge cases
- Empty problems row: dropped on save. Duplicates (case-insensitive): de-duplicated. More than 10: blocked in UI and DB.
- Blank number input (NaN): saved as null. Negative TDS/hardness and pH outside 0–14: rejected.
- Create without any water values: no follow-up write.
- Backfill: free-text address source "Corporation"/"Borewater" maps to the enum; any other text maps to `other` plus text (≤100). Out-of-range TDS/pH is skipped. Existing customer values are never overwritten. Address `health_condition` text is carried into `household_problems`.

## Acceptance criteria
1. Edit customer shows Water & household exactly once (step 3), pre-filled from the saved values.
2. Water values entered at create show on the detail page, technician job and customer app.
3. No family count in any Water & household block. The Family header count excludes moved-out members (admin and customer app).
4. Hardness and problems save and show everywhere. Health condition appears nowhere.
