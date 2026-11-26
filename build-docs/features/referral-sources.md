# Feature: Referral sources everywhere + customer quick-add (2026-11-26)

## Purpose
"Referred by" today is technician-only on New Sale, New Complaint and Sell AMC,
technician/staff-only on New Customer, and on leads depends on Source.
The owner needs every referral spot to accept: Technician, Sales person/staff,
Existing customer (with a quick-add for customers not in the system yet), or
Someone else (name + phone). Customer referrers earn referral points automatically.

## Owner decisions (2026-11-26)
- Walk-in / Lead stay **Sources**, not referrers (would count walk-ins as referrals).
- All 6 screens: NewLeadForm, LeadDetailFieldsCard, CustomerFormPage, NewSalePage, NewComplaintPage, SellAmcPanel.
- Customer referrer is **linked by id** (`referred_by_customer_id`), not free text.
- Customer referrers get **auto-credited points**.

## Architecture
### Frontend
- `components/shared/ReferrerField.tsx` (new): kind chooser (None / Technician / Sales person-staff / Existing customer / Someone else) + the matching input.
  - Technician, staff: existing `ReferrerPicker` with `kindFilter`.
  - Customer: existing `Autocomplete` + `useCustomerAutocomplete`, plus a "+ Add new customer" button.
  - Someone else: name + phone inputs (existing validation rules).
  - Value: `{ kind, userId, customerId, name, phone }`. Changing kind clears the other kinds' fields.
- `components/shared/QuickAddCustomerDialog.tsx` (new): Name (required), Mobile (required, same 10-digit rule as the customer form), Area (optional).
  Reuses `DuplicateContactWarning` lookup. If the mobile already belongs to a customer, it offers "Use this customer" instead of creating a duplicate.
  Creates the customer with `createCustomerWithDetails` (no new RPC) and returns them as the selected referrer.
- `ReferredBySection.tsx`: Technician / Reporting staff sources keep their direct pickers; the **Referral** source shows `ReferrerField` (all kinds); Customer app keeps the customer search.
- The 3 technician-only `<select>`s (Sale, Complaint, AMC) are replaced by `ReferrerField`.

### Database (one migration, applied only on owner's "go apply")
- `customers.referred_by_customer_id`, `leads.referred_by_customer_id` → `customers(id)`, nullable.
  - Check: a customer can't have both `referred_by_user_id` and `referred_by_customer_id`; can't refer themselves.
  - Same set-once guard as `_guard_customers_referred_by_user_id` (first write wins; correction only via the audited path).
  - Same-org validation in every RPC that sets it (FK alone doesn't check org).
- `create_customer_with_details`: new defaulted param `p_referred_by_customer_id`.
- `_carry_over_lead_referral`: also carries `leads.referred_by_customer_id` → customer, with the same ambiguity/history checks.
- `create_sale`, complaint create RPC, `sell_amc_plan`: new defaulted params `p_referred_by_user_id`, `p_referred_by_customer_id`, `p_referred_by_name`, `p_referred_by_phone`.
  - Technician: unchanged path (finder lead, `owner_id` → finder credit).
  - Others: one shared helper `_record_transaction_referrer` inserts a `referral`/`won` lead with the referrer fields (no `owner_id` → no finder credit), and sets the customer's referrer only if it has none and no prior qualifying history (same rule as the carry-over). The staff bonus then flows through the existing `referral_bonus_events` machinery.
- Auto points: `settings.customer_referral_points int not null default 0` (0 = off), editable by master in Masters → Settings.
  AFTER INSERT trigger on `invoices`: if the invoice's customer has `referred_by_customer_id` and no auto award exists yet for that customer, insert one `referral_points` row for the referrer.
  - `referral_points.source text` + partial unique index on `(ref_id) where source = 'customer_referral'` → at most one award per referred customer, safe under concurrency.
  - Errors in the award are written to `audit_log` and never block the invoice.

## Impact map
| Touches | Risk |
|---|---|
| `create_sale`, `sell_amc_plan`, complaint create RPC | Money path. Live bodies md5-pinned before editing; params are additive with defaults so old callers keep working. Regressions in billing = top risk. |
| `create_customer_with_details`, `_carry_over_lead_referral` | Listed as "other window owns" in the 2026-11-02 incentive stream — owner to confirm that's closed. |
| `referral_points`, `invoices` trigger | Points show in the customer app and are redeemable in `create_sale`; a duplicate award = real money. Unique index prevents it. |
| `referral_bonus_events` / staff bonus | Staff referrer set at sale now feeds the existing staff bonus; same eligibility rules, no new rates. |
| Reports: ReferralBonusReportTab, CustomerDetailPage / LeadDetailPanel referrer display | Must show customer referrers too, or they look blank. |
| `types/database.ts` | Hand-patched (no Docker for gen types). |
| Drafts in NewSalePage / NewComplaintPage | Saved drafts hold `referredByTechnicianId`; restore must map old drafts to `{kind:'technician'}`. |
| RPC grants | Any DROP FUNCTION re-grants execute (2026-11-11 lesson); new functions revoked from anon. |

## Edge cases and failure modes
- Referrer = the customer being billed/created → rejected (UI hides them; RPC raises).
- Quick-add with an existing mobile → offer the existing customer, no duplicate.
- Quick-add network failure → dialog stays open with the error; nothing selected.
- Area-only quick-add counts as set up (`needs_setup = false`): same rule the app already uses in `services/customers.ts` (area alone clears it). Kept consistent, not special-cased.
- Customer referrer deleted/merged → FK `on delete set null`; points already awarded stay.
- Two invoices inserted at the same moment for a referred customer → unique index, only one award.
- Points setting 0 → no awards, no errors.
- Lead with old free-text `referred_by_name/phone` → still displayed; no backfill.
- Operation admin on New Complaint can use quick-add (customer create is allowed for that role — verify RLS during build).

## Acceptance criteria
1. All 6 screens offer None / Technician / Sales person-staff / Existing customer / Someone else (lead form: under the Referral source).
2. Walk-in is not a referrer option anywhere.
3. "+ Add new customer" asks Name, Mobile, Area (optional), creates the customer, and selects them as referrer.
4. An existing mobile in quick-add offers the existing customer instead of creating one.
5. A technician referrer on Sale/Complaint/AMC behaves exactly as before (finder credit unchanged).
6. A customer referrer is saved as `referred_by_customer_id` on the lead/customer and is shown on the detail pages.
7. With `customer_referral_points = N > 0`, the referrer gets N points exactly once, on the referred customer's first invoice.
8. Self-referral and cross-org referrers are rejected by the DB.
9. `tsc`, vitest, SQL tests (rolled-back transaction ending in RAISE) all pass; no anon EXECUTE on new/changed functions.

## Status
- R1 DONE: `lib/referrer.ts` (+14 tests), `ReferrerField`, `QuickAddCustomerDialog`, lead `ReferredBySection` wired (Referral source = full chooser; Customer app = customer search + quick-add). A customer referrer on leads still persists as name/phone until R2 adds `referred_by_customer_id`.
- R2 APPLIED LIVE 2026-11-26 (version registered; post-checks: 5 cols, 4 wrappers authenticated-only, 0 anon EXECUTE, points OFF in both orgs, create_sale md5 unchanged, carry-over md5 now 7af63971): `20261228100000_referral_sources.sql`. Changed from the plan: the 3 billing RPCs are **wrapped**, not edited (`*_with_referrer` call the unchanged originals in the same transaction); `create_customer_with_details` likewise wrapped by `create_customer_with_referrer`. Points credit on the first **paid** invoice. Only master/sales staff can create customers (RLS), so quick-add must be hidden for operation_admin on New Complaint (R3).
- R3+R4 DONE: all 6 screens wired, detail pages show customer referrers, points switch in Masters → Settings. New Customer offers no "Someone else" (a customer record only links a profile or a customer).
