# Spare hand-over feature audit — 2026-10-27

Scope: audit the LIVE spare hand-over / technician stock / return feature (migrations applied through `20261024171000`) against 7 requirements. Agent: spare-handover-completion (worktree `GV_mart_spares`, branch `feat/spare-handover-completion`).

Tables involved: `spare_handovers`, `spare_handover_items`, `technician_stock_levels`, `spare_returns`, `spare_return_items`, `inventory` (`location='warehouse'`), `inventory_movements`.

Key RPCs: `create_spare_handover`, `admin_sign_spare_handover`, `confirm_spare_handover`, `create_spare_return`, `create_service_invoice` (spare-deduction section).

---

## Requirement 1 — Master/operation admin (not sales_admin) hand spares to ONE technician

**MET.**

- `public.is_ops_staff()` (latest def: `gv-mart/supabase/migrations/20261015110000_current_role_active_gate.sql` lines 24-27) = `current_role() in ('master','operation_admin')` — explicitly excludes `sales_admin`.
- `create_spare_handover(p_org_id, p_technician_id uuid, p_date, p_items)` (`gv-mart/supabase/migrations/20260921120000_spare_handover_per_technician_stock.sql`) takes exactly one `p_technician_id`, and both the RLS policy `spare_handovers_write_ops` (`20260701091300_rls.sql:367-369`, `is_ops_staff()`) and an explicit in-function `if not public.is_ops_staff() then raise exception` guard enforce the role check twice (belt-and-braces).
- `admin_sign_spare_handover` (`20260702200100_technicians_admin_functions.sql:70-98`) has the same `is_ops_staff()` guard.

## Requirement 2 — Hand-over as one block (header + item lines), who gave it, which technician, when; technician acknowledges the whole block; disputed quantity flagged to staff

**PARTIAL.**

- Block structure: MET. `spare_handovers` is the header (`id, org_id, technician_id, date, admin_sign_url, tech_sign_url, status`), `spare_handover_items` holds N lines (`spare_id, qty_given`) via `handover_id` FK (`gv-mart/supabase/migrations/20260701090800_technician_ops.sql:24-50`). `create_spare_handover` inserts the header once and loops `p_items` into N item rows in one call (atomic within one RPC invocation, invoker transaction).
- Which technician, when: MET (`technician_id`, `date` columns).
- Who gave it: **MISSING.** No column on `spare_handovers` records which staff member (profile id) created the hand-over. `admin_sign_spare_handover` only stores a signature IMAGE URL (`admin_sign_url`), not an identity; `create_spare_handover` never writes `auth.uid()` anywhere. Grepped every migration that `alter table ... spare_handovers` — only the RLS-enable statement, no column ever added for this. No frontend screen (`TechniciansSpareHandoverPage.tsx`, `HandoverPrintSheet.tsx`) displays or captures who gave it either.
- Technician acknowledges the whole block: MET. `confirm_spare_handover(p_handover_id, p_tech_sign_url, p_admin_sign_url)` (`20260702120000_technician_phase7_functions.sql:310-338`) flips `status` to `confirmed` only once both signatures are present, and the technician signs the whole handover row (not per line) — `SpareHandoverPage.tsx` renders every item in the block and a single sign-and-confirm action for all of them together.
- Disputed quantity flagged to staff: **MISSING.** There is no column anywhere (`spare_handover_items` has only `qty_given`/`qty_returned`, no `received_qty`/dispute field), no RPC, and no notification type for a technician to say "I received less/more than this line says." The technician's only two choices today are: sign (accept everything as given) or not sign (leave it pending forever, silently, with no staff alert). Confirmed via `grep -ri "dispute"` across `src/` and `supabase/migrations/*.sql` for anything spare-related — zero hits.

## Requirement 3 — Each technician has own inventory, sees only his own; staff see all; customers/anon see nothing

**PARTIAL** (backend fully correct; no frontend screen for the technician to see his own balance).

- `technician_stock_levels` (`20260921110000_technician_van_stock_schema.sql:27-51`) is the per-technician ledger (`unique(org_id, technician_id, item_type, item_id)`), replacing an earlier pooled `inventory location='van'` bucket that the same migration's header documents as a real bug (one shared number across every technician).
- RLS: `technician_stock_levels_select_staff` (`org_id = current_org_id() and is_staff()`) + `technician_stock_levels_select_own` (`technician_id = current_technician_id()`) (`20260921110000` lines 45-48). `is_staff()` = master/operation_admin/sales_admin (all three see all technicians' stock — correct per requirement's "staff"). No policy at all for `customer`/anon role → default-deny under RLS, i.e. zero access. Confirmed no grant to `anon`.
- Gap: **no frontend screen** queries `technician_stock_levels` from the technician side at all (`grep -rln "technician_stock_levels" src/app/technician/` → zero results). The technician app only has "today's hand-over" (`SpareHandoverPage.tsx`) and hand-over history (`SpareHandoverHistoryPage.tsx`) — neither shows his current running stock balance per spare. The RLS already supports it; only the UI is missing.
- Staff-side view exists: `TechniciansStockLevelsTab.tsx` (`src/app/admin/technicians/TechniciansStockLevelsTab.tsx`) shows every technician's current balance via `useAllTechnicianStock`.

## Requirement 4 — Job-use deduction hits the technician's OWN inventory, never double-deducts central inventory

**MET.**

- Current live body of `create_service_invoice` (latest def: `gv-mart/supabase/migrations/20261016160000_rental_generator_scheduling.sql` lines 147-450, spares loop lines 280-326): for each spare line, a single conditional `UPDATE technician_stock_levels ... WHERE stock_qty >= qty` tries the technician's own van balance first (reason tag `service_use_van`). Only if that UPDATE affects 0 rows (`v_new_stock is null`) does it fall back to a *second*, mutually-exclusive conditional `UPDATE inventory ... location='warehouse'` (reason tag `service_use_shortfall`). The two branches are `if/else`, never both — confirmed no code path runs both updates for the same item line, so central (`warehouse`) stock is never touched when the technician's own stock already covered the line, and is touched exactly once (not twice) when it does cover the shortfall.
- No other trigger decrements inventory for a job: the only triggers on `invoice_items`/`service_spares_used` are `audit_master_change` (`20260702110000_service_amc_schema.sql:34-37`), pure audit logging, no stock side-effects.

## Requirement 5 — Return deducts technician stock, adds central stock, confirmed by master/operation admin

**MET.**

- `create_spare_return(p_org_id, p_technician_id, p_date, p_items)` (`gv-mart/supabase/migrations/20260921130000_create_spare_return.sql`): guarded by the same `if not public.is_ops_staff() then raise` pattern (line 46-48) plus RLS `spare_returns_write_ops`/`spare_return_items_write_ops` (`20260921121000_technician_stock_write_policy.sql:18-24`), both `is_ops_staff()`-only — i.e. only master/operation_admin can ever call it, matching "confirmed by master or operation admin."
- Per item: conditional `UPDATE technician_stock_levels ... WHERE stock_qty >= qty_returned` (decrement, fails loudly if the technician doesn't hold enough) immediately followed by an upsert `INSERT ... ON CONFLICT ... DO UPDATE` onto `inventory location='warehouse'` (increment) inside the same function call — both sides of the movement happen atomically.
- Design note (documented in the migration's own header, `20260921110000` lines 53-58): this is deliberately a single-step "staff records what already physically happened" flow, not a technician-request-then-staff-confirm two-step workflow — no technician-side return-request RPC exists anywhere (`grep` across `src/app/technician/` and `src/hooks/useTechnician.ts` for return-request UI: zero hits). Read literally, "confirmed by master or operation admin" is satisfied because the action can only ever be performed/authorized by that role; there is no unconfirmed/pending return state to separately confirm.

## Requirement 6 — No negative balances; shortfall when technician has no recorded stock is flagged, not lost

**PARTIAL.**

- No negative balances: **MET**, two layers. (a) `technician_stock_levels.stock_qty integer not null default 0 check (stock_qty >= 0)` and `inventory.stock_qty ... check (stock_qty >= 0)` (`20260921110000` line 33; `20260701090300_catalog_inventory.sql` line 64) — a hard DB constraint. (b) Every deduction path (`create_spare_return`, `create_service_invoice`) uses a conditional `UPDATE ... WHERE stock_qty >= qty` and raises an exception when 0 rows are affected, so the constraint is never even approached, and the caller gets an explicit error instead of a silent clamp.
- Shortfall flagged for staff: **MISSING** the "flagged" half. When a technician's own stock can't cover a job's spare use, `create_service_invoice` tags the `inventory_movements` row with `reason = 'service_use_shortfall'` (`20260921140000_service_use_van_stock_and_shortfall_tagging.sql`, carried into every later redefinition through `20261016160000`) — but nothing ever reads that tag to raise a staff-visible alert. Confirmed by `grep -rln "service_use_shortfall" src/` → zero results (it only exists inside SQL migration bodies, never queried by any frontend file), and there is no trigger on `inventory_movements` that fires a `notifications` row for this reason (contrast with the separate, unrelated low-stock trigger `_notify_technician_low_stock` on `technician_stock_levels`, `20260921150000_technician_low_stock_alert.sql`, which only fires on a *downward crossing of the warehouse `min_stock` threshold* — a different condition entirely, not "technician had zero recorded stock for this spare"). So today a shortfall silently falls back to warehouse stock with no staff notification at all; it is recorded (not lost from the books — the warehouse deduction and movement row are real), but not flagged as the requirement demands.

## Requirement 7 — Staff ledger per technician: handed over, used, returned, balance

**PARTIAL.**

- Current staff screen (`TechniciansStockLevelsTab.tsx`) shows: (a) current balance per technician/spare (`useAllTechnicianStock` → `technician_stock_levels`), and (b) a combined chronological log of hand-overs and returns only (`buildStockLog()` in `src/services/techniciansAdmin.ts:1001-1020`, built from `useSpareHandovers` + `useSpareReturns`).
- Missing: the log/ledger never includes **used** quantities (`service_spares_used`, or the `service_use_van`/`service_use_shortfall` rows in `inventory_movements`) per technician — so "handed over, used, returned, balance" is only 3 of 4 columns (handed over, returned, balance are present in one form or another; used is entirely absent from any staff-facing view). `inventory_movements` already carries `technician_id` + `reason` for all four movement kinds since `20260921110000`/`20260921140000`, so the raw data exists; it's just never aggregated into one per-technician ledger.

---

## Summary table

| # | Requirement | Status |
|---|---|---|
| 1 | Master/operation admin (not sales_admin) hand to one technician | MET |
| 2 | Block entry, who/which/when, whole-block ack, dispute flagged | PARTIAL — "who gave it" and dispute-flagging missing |
| 3 | Per-technician own inventory, staff-all, customer/anon-none | PARTIAL — RLS/backend correct, no technician-facing "my stock" screen |
| 4 | Job use deducts own stock only, no double central deduction | MET |
| 5 | Return moves tech→central, confirmed by master/op admin | MET |
| 6 | No negative balances; shortfall flagged | PARTIAL — negative-balance guard solid, shortfall never flagged to staff |
| 7 | Staff ledger: handed over / used / returned / balance | PARTIAL — "used" column missing from the existing log |

Gaps to build (Step B/C): requirement-2 `given_by` + dispute flow, requirement-3 technician "My spares" balance screen, requirement-6 shortfall notification, requirement-7 full ledger (adds "used").

(A copy of this report also lives at `C:\Users\JESHEEBA\Desktop\GV_mart\_local_only\reports\spare_handover_audit.md` per the task's requested path; that path is outside this worktree's tree so it cannot itself be committed on this branch — this file is the committed copy.)
