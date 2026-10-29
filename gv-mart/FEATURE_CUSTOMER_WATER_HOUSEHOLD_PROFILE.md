# Feature: Customer water and household profile

Owner: GV Mart. Build end to end as one feature on one branch: `feat/customer-water-profile`, off `origin/main`, in your own git worktree.
Migration version: `20261108100000` (confirm it is free).

## 0. How to work (read first)

1. **Plan before coding.** Read the code, then post a plan in the chat (files, tables, screens, tests, risks). If the plan has no conflict with this document, start building straight after posting it. If you find a conflict or a decision only the owner can make, stop and ask one clear question.
2. **Reuse what exists.** Water source, TDS and pH already exist per service visit in `ro_checklists` (`water_source` enum `water_source_type`, `water_tds_ppm`, `water_ph`). Family members already exist as the people list `customer_members`. Do not duplicate them. Do not change the per-visit checklist.
3. **No database writes by you.** Never run anything against the live database. No `supabase db push`. Write the migration, rollback, tests and the rehearsal wrapper and type them in full in the chat. The owner applies nothing until the reviewer (Claude in the review window) issues a typed `GO APPLY` quoting the commit and the sha256.
4. **No push to `main`.** Push the feature branch only. The owner pushes `main`.
5. **Never print** API keys, tokens, passwords, full phone numbers or WhatsApp message ids. The only test phone is "the number ending 6740".
6. **No WhatsApp sends of any kind** from this feature.
7. Work only in your own git worktree. Never touch the shared GV_mart folder.

## 1. What the client wants (from the owner's sketch)

A customer profile that holds, in plain form:
1. **Water source**: Bore, Corporation (and other).
2. **Water TDS**: a number, for example 570.
3. **Water pH**: a number, for example 6.5.
4. **Family members**: a number, for example 5.
5. **Health condition**: four levels: No, Normal, Medium, High.

## 2. What already exists (audit at commit a3e2138)

| Field | Status today |
|---|---|
| Water source | `ro_checklists.water_source`, enum values `corporation`, `borewater`, `other`, plus `water_source_other` text. Per visit. Technician enters it on site (`OnSiteVisitPage.tsx`). Shown on `TicketDetailPage.tsx` and `TdsSuggestionDialog.tsx`. Not on the customer. |
| Water TDS | `ro_checklists.water_tds_ppm numeric(6,2)`. Per visit. Separate from `tds_before`/`tds_after` and from the regional estimate table `water_quality_reference`. |
| Water pH | `ro_checklists.water_ph numeric(4,2)`. Per visit. The screen enforces 0 to 14; the database does not. |
| Family members | `customer_members` list (name, mobile, is_primary, relation, profession, email, moved_out_at, google_review_stars; max 5; one primary). Edited by admin (`FamilyMembersPanel.tsx`) and by the customer (`CustomerProfilePage.tsx`). No numeric field. No technician screen. |
| Health condition | Nothing anywhere. |

## 3. Design

### 3.1 Customer-level fields (new, on `customers`)
- `water_source` using the existing enum `water_source_type` (values `corporation`, `borewater`, `other`); optional `water_source_other text` (max 100) used only when `other`.
- `water_tds_ppm numeric(6,2)` nullable, check `>= 0`.
- `water_ph numeric(4,2)` nullable, **check between 0 and 14** (the database enforces it, not only the screen).
- `health_condition` new enum `household_health_level` with values `none`, `normal`, `medium`, `high`; nullable (not yet asked).
- No stored family member count. The count is derived: active members = `customer_members` where `moved_out_at is null`. Do not add a duplicate number column.

### 3.2 Per-visit data stays as it is
The `ro_checklists` fields and the technician checklist step are unchanged. They remain the history of what was measured on each visit.

### 3.3 Latest on-site reading (read-only, derived)
On the customer detail page show the latest `ro_checklists` water reading (source, TDS, pH) and its date, read from the most recent row of that customer. Nothing is copied into `customers`, so the two cannot drift. Provide this through one small read function or view that is org-scoped and staff-only; state which in the plan.

### 3.4 Screens
- **Admin customer form** (`CustomerFormPage.tsx`): edit the four profile fields. Editable by master, operation_admin and sales_admin (same roles that can edit customers today). Show "Family members: N" as read-only text with a link to the Family tab.
- **Admin customer detail** (`CustomerDetailPage.tsx`): a "Water and household" card showing the four fields, the latest on-site reading with its date, and "Family members: N".
- **Technician job detail** (and history detail): show water source, TDS, pH and "Family members: N" read-only so the technician can advise on site. Show the health condition level **only** if the setting `show_health_condition_to_technicians` is on (new boolean in `settings`, default false).
- **Customer app** (`CustomerProfilePage.tsx`): the customer can see the profile fields; whether they can edit them is a decision for the owner (default: read-only for water fields, read-only for health; the family people list stays editable as today). State the decision in the plan.

### 3.5 Health condition is sensitive personal data
- Readable by master, operation_admin, sales_admin and the customer themselves; technicians only via the setting in 3.4 (level only, no free text).
- It must never appear in: WhatsApp messages or templates, CSV exports, reports and dashboards, the activity feed, or notifications.
- Changes are recorded by the existing audit mechanism only if the `customers` table is already audited; do not add a new audit trigger that copies the value anywhere else.
- Write one line in the design note: the meaning of "health condition" (for example, a household member whose condition affects the water recommendation) is to be confirmed by the client; the field is a four-level scale, nothing more.

## 4. Security and database rules

- Keep the existing `customers` RLS policies. No new broad read. A customer reads only their own row; staff read their organisation's rows; technicians keep only the access they have today to customers.
- Any new function: explicit `revoke ... from public, anon, authenticated`, then only the grants needed; fixed `search_path`; org-scoped; staff-only where it exposes staff data.
- Never test `current_user` or `session_user` inside a `SECURITY DEFINER` function (it is always the owner there). Client-detecting triggers must be `SECURITY INVOKER`.
- Any redefinition of an existing function (for example a customer read RPC) must be built from the live body: embed the original text, recreate it in a sub-block in the wrapper, compare `md5(pg_get_functiondef(...))` with the live function, roll back that sub-block, refuse on a mismatch, and type a diff of the old body against the new one.
- Do not edit the repeatedly redefined shared RPCs (`create_sale`, `create_quotation`, and similar) for this feature.

## 5. Database deliverables (typed in full in the chat)

For `20261108100000_customer_water_profile`:
1. Migration: the new enum, the new columns, the new setting, the checks, and any read function or view from 3.3.
2. Rollback (drop the columns, the enum, the setting and any function; it must refuse if any profile data exists, with a clear message).
3. Test file, using a throwaway `__TEST_` organisation. Cover at least:
   - pH below 0 and above 14 are refused; 0 and 14 are accepted; TDS below 0 is refused;
   - water source accepts the three enum values; `water_source_other` only with `other` (state the rule);
   - health condition accepts the four values and refuses others;
   - master, operation_admin and sales_admin can set the fields; a customer cannot set them (or can, per the decision in 3.4); a technician cannot;
   - a customer reads only their own profile; another organisation's staff read nothing;
   - the latest-reading function returns the most recent visit's values and its date, org-scoped and staff-only;
   - a technician sees the health level only when the setting is on;
   - a real organisation's customers are unchanged by the migration (relative fingerprint taken before the migration and compared at the end).
4. Rehearsal wrapper in the standard form: ONE `DO` block; refuses when `(clock_timestamp() at time zone 'Asia/Kolkata')::time < time '18:00'`; embeds the migration and test text with sha256 recomputed and pinned in the block; runs them with `EXECUTE`; no top-level begin/commit/savepoint/rollback; ends in an unconditional `RAISE EXCEPTION 'RESULTS…'`; never concatenated with the migration in the request; relative counts only.
5. All hashes as sha256 of the LF blobs. Check pure LF at the byte level.

## 6. Front-end deliverables

- Admin customer form fields, detail card, derived family-member count, latest reading.
- Technician job detail and history detail read-only display, with the health setting rule.
- Customer app read-only (or editable per the decision).
- Translations for every new label (English now; keep the existing language setup).
- `tsc` clean, `oxlint` clean on touched files, vitest passing, with new tests for the pH range helper, the health visibility rule and the derived count.
- The front end must not crash if the migration is not applied yet (deploy-order safety): treat missing columns as "not available".

## 7. Deploy order (write into the design note)

1. Rehearsal (rolled back, after 18:00 IST).
2. `GO APPLY` from the reviewer: backups first, version registered in the same transaction, read-only checks afterwards, stop at the first failure.
3. Deploy the web app (Vercel) from `main` after the owner merges.
4. Capacitor rebuild and sync from `main` so the technician screens show on phones.
5. Phone check as the test technician and as master.

## 8. Manual test script (include in the design note, about 8 lines)

As master: open a customer, edit the Water and household card: source Bore, TDS 570, pH 6.5, health Medium; save. Try pH 15: it must be refused. Open the detail page: the card shows the values, the latest on-site reading with its date, and "Family members: N". As the test technician: open a job for that customer: source, TDS, pH and the family count show; the health level does not. Turn the setting on as master: the health level now shows to the technician.

## 9. Defaults chosen (the owner confirms with the client later)

- Health condition: four-level scale only; sensitive; hidden from technicians by default.
- Customer app: read-only for the new fields.
- Family members: derived count, no stored number.
- Editors: master, operation_admin, sales_admin.

## 10. Acceptance

- The five items on the sketch are all visible on the customer profile, with family members shown as a derived count.
- The database refuses a pH outside 0 to 14.
- The health condition never leaves the allowed screens.
- The per-visit checklist is unchanged.
- All tests pass locally; the migration, rollback, tests and wrapper are typed in the chat with hashes.
- Nothing was run against the database. Nothing was pushed to `main`.
