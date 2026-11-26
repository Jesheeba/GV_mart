# CHANGELOG — Leads Dashboard Enhancement

## referral-sources R3+R4 (2026-11-26)
- New Customer, New Sale, New Complaint, Sell AMC use `ReferrerField`; non-technician referrers go through the `*_with_referrer` RPCs, technician keeps the original finder-credit path. Old drafts with `referredByTechnicianId` restore as a technician referrer.
- Leads save `referred_by_customer_id`; customer + lead detail show a customer referrer (click opens that customer).
- Masters → Settings → AMC & referral: "Customer referral points" switch (OFF) + points per referred customer; on requires points > 0.
- Quick-add hidden for operation_admin on New Complaint (only master/sales can create customers).

## referral-sources R2 (2026-11-26) — migration APPLIED LIVE 2026-11-26 (owner "go apply")
- `20261228100000_referral_sources.sql` (+ `.rollback.sql`): `referred_by_customer_id` on customers + leads with guards; points toggle (`settings.customer_referral_points_enabled` / `customer_referral_points`, OFF / 0); once-per-customer award on first paid invoice; carry-over also carries a customer referrer; wrappers `create_customer_with_referrer`, `create_sale_with_referrer`, `create_complaint_ticket_with_referrer`, `sell_amc_plan_with_referrer`. create_sale / create_complaint_ticket / sell_amc_plan / create_customer_with_details bodies untouched.

## referral-sources R1 (2026-11-26)
- New `ReferrerField` (Technician / Sales person-staff / Existing customer / Someone else) and `QuickAddCustomerDialog` (Name, Mobile, Area optional; offers the existing customer when the mobile matches).
- Lead form: Referral source shows the full chooser; Customer app source gets quick-add. No DB change.
## choice-dropdowns-not-set (2026-11-26)
- Every either/or data-entry field is a `ChoiceSelect` dropdown with "Not set" first and nothing pre-selected (about 45 screens: sales/payments, purchase, accounts, leads, service, on-site, tasks, HR, expenses, masters, automation, family relation). Plan: features/choice-dropdowns-not-set.md.
- Optional fields save "Not set" as empty: on-site water source, tank cleaned, product explained; member relation; lead product category and kind; technician tier override (clears to base tier).
- Address type and ownership save "Not set" as null via migration `20261229100000_address_choice_not_set` (rehearsal 12/0). **APPLIED LIVE 2026-11-26** (backup in `_local_only/backups/2026-11-26_address_choice_not_set`).
- Required fields show "Not set" but block Save with an inline error and focus: payment methods, expense categories, lead source, follow-up type, channel, outcome, lost reason, complaint and task priority, enquiry fields, roles, statuses, item types, units, doc types, phrase category, segment rules.
- On-site payment method: merged with main's fix f8d0645 (chosen on the invoice step, UPI accepted); that chooser is now the dropdown.
- Removed pre-selections: enquiry type "online", complaint and task priority "normal", lead source "other", bill category "purchase", spare interval "months", bot phrase category, segment rule parts, ReorderableListCard first option.
- EntityCrudTable and ReorderableListCard show "Not set". ReorderableListCard now validates before save, like EntityCrudTable.
- i18n: added `common.notSet`, `service.errors.*` (missing before, so the complaint form showed raw keys) and `confirmedAvailability.reasonLabel`. Removed 4 unused keys.
- GST Extra/Included keeps the org-setting default (owner).

## choice-dropdowns (2026-11-26)
- Owner request: Address type, Ownership (admin customer form + customer app address form) and Water source are dropdowns instead of pill buttons. Shared `components/shared/ChoiceSelect.tsx`; nothing pre-selected (required: disabled "Select…"; water source: "Not set").
- Water TDS / pH / hardness inputs no longer show the up/down stepper arrows (`NO_SPINNER` in `lib/fieldWidth.ts`).
- New i18n key `common.notSet` (en/ta). No DB change.

## onsite-payment-method (2026-11-26)
- On-site payment method is chosen on the invoice step, unselected + required when the total is above 0, so the invoice records the real method and transfer reference (it always recorded "cash" before). Payment step shows it read-only.
- `servicePaymentSchema` accepts `upi`, so UPI visits can complete. Doc: `features/onsite-payment-method.md`.

## customer-data-sync (2026-11-26)
- See features/customer-data-sync.md for the 7 sweep fixes: primary member sync, one email box, app address no longer overwritten, profession no longer reverted, moved-out members never counted, drafts keep complaint type and referrer, lead fields card never stale.
- Migration `20261216120000_primary_member_sync.sql` + rollback. **APPLIED LIVE 2026-11-26.**
- Changed test: `address.test.ts` "treats a populated area alone as a structured field" was replaced. It asserted the behaviour that dropped customer-app addresses.

## customer-water-household + water-solution-followup (2026-11-26)
- Edit customer showed Water & household twice: step-1 panel (customers row) and step-3 form (addresses row). Now one step 3 in both modes, backed only by the customers row.
- Create no longer writes `addresses.water_*`, which nothing displayed. Water values typed at create now show on the detail page, technician job/history and customer app.
- Family count removed from every Water & household block. The customer app's members and count now exclude moved-out members.
- Added Total hardness and "Problems faced" (list, + add another). Health condition removed from all screens and dropped from the DB.
- Added Recommended solution and Follow-up date. The date creates one task for the master. Tasks gets Postpone (later date + reason) and Convert to lead (opens New Lead prefilled, closes the task when saved). Daily 09:00 IST due reminder.
- Shared `WaterHouseholdFields` (edit) / `WaterHouseholdSummary` (read-only) replace four hand-copied blocks.
- Migrations `20261216100000`, `20261216110000` + rollbacks + SQL tests. Rehearsal 90/90; **APPLIED LIVE 2026-11-26** (backup in `_local_only/backups/2026-11-26_customer_water_household_v2`).
- Also removed a pre-existing unused `fullAddress` variable in CustomerFormPage (failed `tsc` on main).

## UX pass (2026-11-26): choice-no-preselect, input-density, date-display, header wrap fix
- choice-no-preselect (ad28862): address type/ownership (admin + customer app, now the same buttons), payment method (New Sale, Record payment, Rent out, Sell AMC), follow-up type/channel, availability reason, HR/expenses selects, purchase/master item types start unchosen and are required. EntityCrudTable: "Select…" placeholder + required, `defaultValue` keeps Active/pending/No where the DB default matches. New `lib/crudForm.ts`.
- input-density (bc58f8c): `lib/fieldWidth.ts` width map; about 70 short-number inputs fitted, numeric keypads, maxLength where a strict rule exists; form selects unified to h-10.
- date-display (f312368): `formatShortDate/DateTime/DateTimeRange` (IST, year only if not current); dates nowrap; split date/time rows merged; device-TZ formatting replaced; 16 date pickers `w-44`; invoice print date now IST (DD/MM/YYYY).
- Customer header (c7b0851): language picker stays top-right under the action icons instead of wrapping below.

## pin-autocorrect (2026-11-26)
- A technician at the customer but outside a wrong (up to 2 km) or missing pin can start the job. Their GPS becomes the pin automatically, with no office approval. The next in-radius arrival locks it.
- Migration `20261216100000_pin_autocorrect.sql` APPLIED LIVE 2026-11-26 (owner: "go apply"), one transaction, version registered by hand; function md5 2bccb48abbcc71cb918e59bbdfdf32a2: `settings.pin_autocorrect_max_m`, event `corrected`, RPC `record_technician_pin_correction`, FYI notification `pin_autocorrected`. Rollback in `supabase/rollbacks/`.
- App: MapPage "pin is wrong" / "start here" flow plus a reason when blocked; new outbox kind; customer header pin chip (verified / corrected / pinned / not pinned). en/ta strings.

## arrival-location-lock (2026-11-26)
- Migration `20261214100000_arrival_location_lock.sql` APPLIED LIVE 2026-11-26 (owner: "go apply"), one transaction, version registered by hand. Rollback file alongside.
- First in-radius technician arrival locks the address pin (addresses.location_verified_at/by) and logs old vs new pin + distance in new `address_location_events`.
- Arrival RPC re-checks geofence + accuracy (<= 75m) server-side; no longer swaps a secondary address to primary (removes the copy bug that dropped full_address/sub_area/zone/water_*).
- `reset_address_location_verification` (master only, reason required). Guard trigger blocks every other change to a locked pin / verified_* columns.
- App: MapPage sends GPS accuracy; office form shows `VerifiedLocationCard` (read-only, master reset) and never sends lat/lng for a locked address; customer app hides re-pin and shows "Location verified by our technician". en/ta strings.
## customer-form-map-search-prefill (2026-11-25)
- Map search box on the customer Address step now mirrors the typed address fields (door/street/area/PIN/district/state) -- no retyping.
- Mirrored text never auto-opens suggestions or spends a Places call; focusing the pre-filled box searches it once. User-typed text searches live as before.
- Fixed (pre-existing): picking a map suggestion auto-filled blank fields (Main Area/Zone) AFTER the pin snapshot, so the pin was immediately cleared ("Exact location not pinned"). Snapshot now re-taken after the fill via shared `locationText()`.
- Files: `CustomerFormPage.tsx`, `AddressMapPicker.tsx` (also used by `AddressForm`, `AddressPinDialog` -- uncontrolled there, only change is no re-search after picking a result).

## customer-form-compact (2026-11-25)
- `CustomerFormPage.tsx`: Door no / Plot no / Building Name now share one 3-column row.
- All step cards use compact fields (inputs/selects h-8, labels text-xs) via one `COMPACT_CARD` class; page width max-w-2xl -> max-w-xl.
- Styling only; no logic/data changes. tsc clean; no existing tests cover this page.
- Branch: `feat/customer-form-compact`, worktree `_local_only/worktrees/customer-form-compact`.

## lead-category-chips (2026-11-10)
- Removed "All topics" filter and the hidden "Lead type" select from `LeadsPage.tsx`.
- Added a visible category chip bar (All leads / Service / Product / Spare / AMC) bound to the existing `kind` filter — no new column, reuses `leads.kind`/`kind_key`.
- Extracted chip ordering into `leadCategoryChips.ts` + unit tests.
- Removed now-unused `leads.filters.allTopics` i18n key (en/ta); reworded `allKinds` to "All leads".
- Branch: `feat/lead-dashboard-enhancement`, worktree `_local_only/worktrees/lead-dashboard`.

## lead-summary-tiles (2026-11-10)
- Replaced the 4-tile KPI block (Total/Won/Lost/Conversion rate) with 6 tiles: Total, New, Contacted, Quotation, Won, Lost — each shows count + percentage.
- Percentage formula changed to count/total*100 for every tile (previously Won%/Lost% were % of closed leads only); Total shows 100% when leads exist, 0% when none.
- Extracted to pure `leadSummaryTiles.ts` + unit tests; `conversionRate` i18n key and its only usage removed as dead code.

## followed-by-filter (2026-11-10)
- Added a new "Followed by" dropdown on the Leads list, separate from the existing assignment filter — filters by who actually logged a follow-up activity (`lead_activities.created_by`), not who the lead is assigned to.
- New read-only service/hook `listLeadFollowupActors`/`useLeadFollowupActors`; grouping/dedup logic extracted to `followedByFilter.ts` + unit tests (count = distinct leads, never activity-row count).
- No migration, no write path, no change to the existing assignment filter.

## lead-detail-fields (2026-11-10) — LIVE
- New columns on `leads`: `customer_requirement`, `special_description`, `user_source`, `budget`, `when_needed`, `tds_status`, `report_storage_path`; new `lead-reports` storage bucket + `record_lead_document` RPC.
- Caught and fixed before going live: original draft missed "When do they need it?" — added as `when_needed` across migration/types/schema/form/detail card.
- `NewLeadForm.tsx` gets the new optional create-time fields; `LeadDetailPage.tsx` gets a new `LeadDetailFieldsCard` (view/edit the fields + upload/view the document).
- Hand-patched `database.ts` (Docker/`gen types` unavailable in this environment).
- **Applied 2026-11-10 on owner's "GO APPLY"**, via direct `pg` connection (no psql in this environment), one transaction per migration file, versions registered in `supabase_migrations.schema_migrations`. Pre-apply check found the live DB had diverged from this branch (other sessions' migrations up to `20261204190000` not in this branch's history) — checked for collisions before applying; found none. Post-apply verified columns/bucket/function exist via direct query.

## referral-details (2026-11-10) — LIVE
- New columns on `leads`: `referred_by_name`, `referred_by_phone`.
- `NewLeadForm.tsx` and `LeadDetailFieldsCard.tsx` get the two new inputs, grouped as "Referral details."
- **Correction to an earlier correction:** this plan's original decision ("keep both the points-award flow and new freeform fields, don't merge") was right. A mid-build claim that `referred_by_user_id` didn't exist was based on this worktree's stale local checkout — the live-DB check before applying found it (and `referral_type`) genuinely do exist, added by another session. Doesn't change anything about this feature's own columns, which are independent and additive either way.
- Applied in the same run as lead-detail-fields above.

## followup-workspace-reminders (2026-11-10) — no migration needed
- "Today's conversation": relabeled the existing single-line "Add note" into a multiline textarea on the same `add_lead_note` RPC path — no new write path.
- "Next follow-up date/time": unchanged, already the existing `SetFollowupDialog`/`set_lead_followup` RPC.
- "Reminder": new selector in `SetFollowupDialog` (at / 15 min / 1 hour / 1 day before) creates a `tasks` row via the extended `createTask`/`CreateTaskInput` (now exposes `dueAt`/`refType`/`refId`/`description`, which already existed on the table).
- Known gap: reminders are not yet wired into `RescheduleDialog`, and there's no dedup if a lead is rescheduled after a reminder task already exists — documented, not solved in this pass.

## lead-referral-redesign (2026-11-11)
- TDS: dropdown -> free text input (3-preset check constraint dropped).
- Removed duplicate "User source / referred through" field from lead create/detail.
- when_needed surfaced on My Day (list_followups) and no-followup (list_leads_without_followup) cards.
- Referred-by redesigned: Technician/Staff picker, existing-customer search (prefills name/phone), or free-text, shown only for referral/customer_app sources.
- Migration (20261111100000_lead_referral_redesign.sql) APPLIED live 2026-11-11 (owner GO APPLY) — see entry below.
- Verified (not changed): referral-points award on conversion is still manual only, not automatic — see feature doc.

## lead-referral-redesign migration applied live (2026-11-11)
- 20261111100000_lead_referral_redesign.sql applied live on owner's "GO APPLY": tds_status check constraint dropped, reporting_staff source seeded (all orgs), list_followups/list_leads_without_followup redefined with when_needed. Fixed in-flight: CREATE OR REPLACE can't add an output column to a RETURNS TABLE function -- needed DROP FUNCTION first for both RPCs (committed fix matches what ran). Verified live: free-text TDS insert succeeds, reporting_staff rows present, both RPCs expose when_needed.

## regression fix: list_followups/list_leads_without_followup grants (2026-11-11)
- The DROP FUNCTION + CREATE OR REPLACE used earlier today to add when_needed silently dropped authenticated's execute grant on both RPCs (new function object, old GRANTs not carried over) -- broke Daily Follow Up for every role, reported as "not loading in master". Fixed live: granted execute back to authenticated on both. New migration 20261111110000_fix_list_followups_grants.sql records it.

## lead-unified-interaction-log (2026-11-11) — no migration needed
- Merged `LogOutcomeSheet.tsx` + `RescheduleDialog.tsx` + the inline "Add note" toggle on `LeadDetailPage.tsx` into one new `LogInteractionSheet.tsx` with a 3-way mode switch (Reached customer / Couldn't reach · push it / Just a note). Deleted the two old files — no lingering dead code.
- `LeadDetailPage.tsx`: one "Log interaction" button (+ a "Reschedule" quick button when a follow-up is already set) replaces the old three separate buttons/toggle.
- `MyDayPage.tsx` / `FollowupCard.tsx`: the two per-row quick-action buttons ("Log interaction", "Reschedule") now open the same merged sheet via one `onLogInteraction(item, mode)` callback instead of two separate dialogs/write paths.
- `CallReturnPrompt.tsx` (auto-opens after a staff member returns to the app post-call) repointed at the merged sheet, defaulted to Mode A with `defaultChannel="call"` — this entry point was missed in the first design-doc draft and fixed before building.
- No new RPC: all three modes call the pre-existing `log_lead_outcome` / `reschedule_followup` / `add_lead_note` RPCs exactly as before; `reschedule_followup`'s already-existing but previously-unused `note` parameter is now actually passed, so a reschedule's conversation note is captured instead of silently dropped.
- Added a stuck-threshold warning (Mode B only — reschedule's postpone rule is unambiguous; outcome-mode has no client-visible field to base a correct warning on, so none is shown there rather than guessing).
- New i18n keys: `leads.interaction.title`, `leads.interaction.mode.{outcome,reschedule,note}`, `leads.interaction.stuckWarning` (en + ta).

## lead-unified-interaction-log: drop the separate quick Reschedule button (2026-11-12)
- `LeadDetailPage.tsx` and `FollowupCard.tsx` (My Day) each had two buttons — "Log interaction" and a quick "Reschedule" — both opening the same merged sheet. Per owner request, collapsed to one "Log interaction" button everywhere; reschedule is now reached only via the mode switch inside the sheet.
- `LeadDetailPage.tsx`: removed `interactionMode` state and the `openInteraction(mode)` helper; the button and the `reopen` path both just call `setInteractionOpen(true)` and let the sheet default to "outcome". The "Set follow-up" button (for leads with no follow-up yet, a different RPC/dialog) is unchanged.
- `FollowupCard.tsx`: `onLogInteraction` prop dropped its `mode` argument; `MyDayPage.tsx` simplified to match (`onLogInteraction={setInteractionFor}`, no `interactionMode` state).
- Removed the now-orphaned i18n keys `leads.followup.logOutcome` and `leads.followup.reschedule` (en + ta) — nothing references them after the button merge; `leads.interaction.title` and the in-sheet mode labels replace them.

## sidebar-pinned-items (2026-11-25)
- Admin sidebar: pin any item to a "Frequently used" section below Dashboard (per user, localStorage). en + ta labels.

## picker-search — 2026-11-26
- Spare picker in New Sale, Quotation, PO/Bill entry is now a type-to-search box (`SparePicker`), replacing a native select whose Space key blocked typing.
- Product/spare search matches every typed word in any order.
- Product labels no longer repeat the model or show the `RO (spreadsheet import)` placeholder brand (display only, data unchanged).

## quick-add F3a: complaint name — 2026-11-26
- `Autocomplete` gains optional `onCreate`/`createLabel`/`creating` ("+ Add" last option, keyboard reachable).
- New Complaint → Name of complaint: master/operation_admin can save a typed name to the product category's master list.
- Migration `20261226100000_quick_add_complaint_type.sql` (SECURITY DEFINER RPC, ops-only, dedupe + advisory lock, anon revoked): **applied live 2026-11-26**, version registered.
- Data: archived duplicate product "ROP WALLMOUNT FILTER (WITHOUT RO)" (c95e5351, zero references, 0 stock) on owner request; "ROP WALLMOUNT FILTER WITHOUT RO" kept.

## gst-inclusive-toggle — 2026-11-26 (migration APPLIED live, version 20261226110000 registered)
- Masters → Settings: "Prices include GST by default".
- New Sale + New Quotation: GST extra / GST included switch, starting at the default. The quotation's choice carries into the sale.
- Invoice print: taxable value = total − GST; "GST amount (included in price)" label for Included bills. The quotation print shows a GST line (new quotations only).
- DB: `settings.prices_include_gst`, `invoices.gst_inclusive`, `quotations.gst_inclusive` (nullable), `_gst_amount()`; 6 billing RPCs + create_quotation updated.
- 2026-11-26 follow-up: the same display rule (`productExtraParts`) is applied to AMC sell, customer detail, lead items, complaint/ticket equipment pickers, ticket detail and 4 customer-app pages. Masters tables still show the raw brand so it can be renamed there.
