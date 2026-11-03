# Incentive overhaul — design only, 2026-11-02

Status: **DESIGN ONLY**. Nothing built, no migration written, no DB touched. Companion to `plan-referral.md` and
`plan-batch2-design.md`. Read before building: `compute_incentives`/`compute_salary` (`20260702200200_hr_functions.sql`
+ every later `create or replace` of them, latest `20261024100500_compute_incentives_bike_allowance.sql`),
`installation_incentive_rates`/`installation_rate_for` (`20261006110000`), `technician_tiers`/`compute_salary`
(`20261001100000`, `20261001110000`), `finder_credit` schema/functions (`20260723130000/1`, `20260724100000`), and the
UI (`IncentiveRulesTab.tsx`, `IncentivesTab.tsx`, `StaffSalaryTab.tsx`, `InstallationRatesTab.tsx`).

**Hard constraint honoured throughout:** `leads.owner_id`/`referral_overview`/`technician_finder_conversions`/the
`finder_credit` branch of `compute_incentives`/`create_sale`'s lead resolution/`sell_amc_plan_onsite`/`renew_amc_plan`'s
referral-name matching are **packages 3–5, in progress in another window — not touched anywhere below.** Every new
piece is additive (new tables, new nullable columns, new append-only blocks in `compute_incentives`), following the
exact pattern the codebase already uses for installation-ticket credits and the bike allowance — each of those added a
new source column + a new appended block, never editing an earlier block.

---

## 1. What exists vs. what the client is asking for

| Client ask | What exists today | Gap |
|---|---|---|
| **Service referral**: one % of revenue, org-wide | Nothing. `finder_credit` is a flat **monthly threshold** amount (e.g. "5 referred tickets → ₹500"), not a %, and not per-referral. A referral today is a `leads` row, not a revenue-linked record. | New: a single org-wide percent setting + a per-referral revenue computation. Must not touch `finder_credit`/`technician_finder_conversions` (owned by the other window) — reads the same `leads`/`service_tickets.lead_id` plumbing read-only. |
| **Sales incentive**: % per product/category, auto from the product's rate | `installation_incentive_rates` is the right *shape* (product_id/category match, most-specific-wins) but only fires on **installs** (`installations_logged`), not on every product/spare sale. `sales_income` incentive type exists but is a flat threshold amount on **total sales value**, and technician attribution is "coincidental" (only works if the salesperson also has a `technicians` row — flagged as weak in `20260716140000_sales_income_attribution.sql`). | New: a product/category **percent** rate table (same match logic as `installation_incentive_rates`), applied to every sold line, credited to whoever actually sold it — which needs a real salesperson attribution, not the technician-only loop `compute_incentives` uses today. |
| **AMC sale referral**: fixed % tiers (2/3/4...) | No tiering exists anywhere in incentives. `finder_credit` is flat-threshold, not tiered, and not AMC-specific. | New: a tier table (rank, min count or min value, percent) scoped to AMC referral volume. |
| **Referrals auto-calculate from referrer name on the form + misuse checkpoint** | Referrer is already resolved from a technician name/picker in 2 of 3 AMC paths (`renew_amc_plan` free-text match, `sell_amc_plan_onsite` = self). Misuse controls that exist elsewhere: `is_active` filtering (used in `compute_incentives`'s technician loop, **not yet** in `compute_salary` — real open bug, F-02 from the 2026-10-29 audit, fixed for salary but informative here), the existing audit trigger (`audit_master_change`), and the master lock-after-posting pattern (`reopen_salary_posting`). | Reuse: active-technician filter, audit trigger, master-review step before a referral-based amount is paid — pattern exists, needs wiring into whatever new referral tables are built. |
| **Warranty visits**: tiny fixed ₹ (e.g. ₹30 filter, ₹75–100 other), not % | `service_visits.service_charge` is **already ₹0** on every warranty/AMC visit by policy (v2.2 §6.2/6.3, enforced in 5+ places) — so a % of revenue is structurally ₹0 today, confirming the client's own reasoning. No technician amount is paid for a warranty visit at all right now. | New: a fixed-amount table + a way to classify a completed warranty visit as "filter/spun" vs "other" — **this classification does not exist anywhere in the schema today** (no such column on `service_visits`, no such product/spare flag). Real build-order decision needed, see §6. |
| **AMC visits**: fixed per-visit (spun-only vs bundled) | Same ₹0-service-charge fact as above. Nothing pays a technician per AMC visit today. | Same new classification need as warranty, scoped separately (AMC visits aren't warranty visits — different ticket `type`). |
| **New installation**: predefined ₹ per product registered, automatic | **Already built and live**, in two parallel mechanisms: (a) `installation_incentive_rates` — a master-set flat ₹ per product/category/capacity/configuration, paid per unit via `installations_logged`, recomputed every `compute_incentives` run; (b) `installation_incentive_credits` — a master-approved, per-ticket ₹ snapshot on `products.installation_charge`. Both are additive to each other and to the old flat-threshold `installation` rule. | **No gap.** This client ask matches path (a) exactly: a master sets ₹150/500/1000 per product in Masters → Installation Rates, and it is already applied automatically. Worth telling the client this one is done; the only decision is whether to also deactivate the old flat-threshold `installation` rule (Masters → Incentive Rules) so it doesn't stack unexpectedly. |

---

## 2. One coherent data model (additive only)

### 2.1 `incentives_earned` — extend the existing "exactly one source" pattern
The table has grown a source column each time a new incentive mechanism shipped (`rule_id` → `+installation_rate_id`
→ `+credit_source` → `+is_bike_allowance`), each time widening a `sum(...) = 1` check constraint. Continuing that
exact pattern (not a polymorphic redesign — this codebase has explicitly chosen boolean/nullable-column widening
over a generic `source_type`/`source_id` pair, four times in a row, so staying consistent is the lower-risk, more
reviewable choice):

```
alter table incentives_earned
  add column service_referral_id   uuid references referral_commission_events(id),
  add column sales_commission_id   uuid references sales_commission_lines(id),   -- or a monthly rollup id, see 4.2
  add column amc_referral_tier_id  uuid references amc_referral_tiers(id),
  add column fixed_visit_rate_id   uuid references fixed_visit_rates(id);
```
...and widen the one-source check from 4 terms to 8. One `incentives_earned` row per technician+period+source, same
as every existing type — this is what freezes the paid amount and is what `compute_salary` already sums unmodified.

### 2.2 New tables (names provisional, master-editable, all seeded empty — nothing pays until a master fills a row,
matching this codebase's standing convention for every rate table so far)

**`service_referral_settings`** (or a single column on `settings`, like `own_bike_allowance_base`) — one org-wide
percent. A single number in a box, exactly as asked: `service_referral_percent numeric(5,2)`.

**`sales_incentive_rates`** — `product_id` (nullable) / `category` (nullable), `percent numeric(5,2)`, `is_active`.
Same shape and same most-specific-wins match function as `installation_incentive_rates`/`installation_rate_for`
(reuse that resolution logic, don't reinvent it).

**`amc_referral_tiers`** — `rank int`, `min_count int` (or `min_value numeric`, see open question in §7), `percent
numeric(5,2)`. Mirrors `technician_tiers`' rank/threshold shape.

**`fixed_visit_rates`** — `visit_context text check (in ('warranty','amc'))`, `outcome text check (in
('filter_only','other'))`, `amount numeric(12,2)`. Two rows per context (4 total: warranty×filter, warranty×other,
amc×filter/spun-only, amc×bundled) — a master types the ₹ once per row, never hardcoded.

**`referral_commission_events`** — one row per referred sale/ticket that completed: `technician_id` (referrer),
`customer_id`, `source_ticket_id`/`invoice_id`, `revenue_amount`, `percent_applied`, `commission_amount`, `period`,
`status` ('pending_review' → 'approved' | 'rejected'), `reviewed_by`, `reviewed_at`. This is the audit trail the
client explicitly asked for ("misuse checkpoint... the audit trail we already have") — reuses the existing
`audit_master_change` trigger pattern plus an explicit master-approval step like `installation_incentive_credits`'s
pending→approved→void lifecycle (same three states, same idea: a technician's own referral never auto-pays without
a master glance).

### 2.3 Schema gap that must be closed before warranty/AMC fixed amounts can work
Nothing in the schema today distinguishes a "spun/filter-change" visit from "other service" on a warranty or AMC
ticket. Two ways to close it, in order of preference:
1. **Infer it from spares used** (`service_spares_used`/`spares`): if the org's spares catalog already tags a
   filter/spun part as its own category, a visit whose only spare line is that category is "filter_only"; anything
   else (including no spares at all, which is still "other" labour) is "other". Needs confirming the client's spares
   catalog actually has a clean filter/spun category — if yes, **zero new UI**, just a read at `compute_incentives`
   time.
2. **Explicit technician-selected outcome** at visit completion (`create_service_invoice`'s existing step) — a new
   required dropdown ("Filter/spun change" / "Other service") stamped onto the visit, used nowhere else. Needed only
   if (1) doesn't hold cleanly for this client's catalog.
This is listed as an open question in §7 — do not guess which one before the client answers.

---

## 3. Master settings screens

All under **Masters → Incentives** (reusing the existing tab strip in `IncentiveRulesTab.tsx`/`InstallationRatesTab.tsx`
as a pattern — add new tabs, don't rebuild the page):

1. **Service Referral** — one box, org-wide percent. (New tab, ~20 lines, same shape as `FlatInstallationBonusCard.tsx`.)
2. **Sales Incentive Rates** — a CRUD table identical in shape to `InstallationRatesTab.tsx`: product or category,
   percent, active flag. Literally clone that component's field/column config and swap `flat_amount` → `percent`.
3. **AMC Referral Tiers** — a small ranked CRUD table (rank, min count, percent) — same shape as the existing
   `technician_tiers` master screen pattern (Masters → Technician Tiers, if that screen already exists; otherwise
   model it on `IncentiveRulesTab.tsx`'s simple CRUD).
4. **Warranty / AMC Visit Amounts** — 4 fixed boxes (warranty-filter, warranty-other, amc-filter, amc-bundled), same
   shape as item 1.
5. **Referral commission review queue** — a new small screen (or a card inside HR → Incentives, next to
   `InstallationCreditsPanel`) listing `referral_commission_events` in `pending_review`, with approve/reject buttons —
   same UX as `approve_installation_credit`/`void_installation_credit`.

No change to `IncentiveRulesTab.tsx`/`InstallationRatesTab.tsx` themselves — new tabs sit beside them.

---

## 4. How each amount is computed, and frozen at month-end

Every type below follows the **same freeze discipline already live for every incentive source**: `compute_incentives`
is a master-triggered RPC (HR → Incentives → **Compute**), never a cron; a "one-shot" source (a rule-threshold row)
is inserted once per technician+period and never revisited; a "live" source (per-unit install rates, installation
credits, bike allowance) is **recomputed on every Compute click until the technician's salary for that month is
posted** — at which point `compute_salary`'s existing lock (`reopen_salary_posting` required to undo) freezes
everything, including every incentive row that feeds it, because `compute_salary` simply refuses to recompute a
posted period. That lock is the actual "frozen at month-end" mechanism in this codebase — not a separate freeze per
incentive type.

1. **Service referral** — "live" source, like per-unit install rates: each `compute_incentives` run re-scans
   completed referred tickets in the period (`service_tickets.lead_id` → `leads.owner_id`, read-only reuse of the
   other window's plumbing — only reading `service_visits.service_charge` × `service_referral_settings.percent`),
   upserts one `referral_commission_events` row per referred ticket, and once a master approves it, sums approved
   events into one `incentives_earned` row per technician/period (same shape as `installation_incentive_credits`'
   aggregation block). Unapproved events never pay — that's the misuse checkpoint.
2. **Sales incentive** — "live" source: for each completed invoice line in the period, resolve the best-matching
   `sales_incentive_rates` row (reusing `installation_rate_for`'s matching logic against `product_id`) and compute
   `percent × line subtotal`; sum per technician into one `incentives_earned` row, recomputed every run.
3. **AMC referral tiers** — "one-shot-ish": per technician per period, count qualifying AMC referrals, resolve the
   matching tier by rank, apply that tier's percent to the AMC sale value(s) that calendar month, write one row.
   Recomputed (not one-shot) so a referral confirmed late in the month still updates the tier before lock.
4. **Warranty / AMC fixed visit amounts** — "live" source: sum `fixed_visit_rates.amount` for every completed
   warranty/AMC visit in the period, keyed by its resolved `filter_only`/`other` outcome; one row per technician per
   period, recomputed every run.
5. **New installation** — unchanged; already live via `installation_incentive_rates`/`installation_rate_for`.

All five feed `compute_salary`'s existing `incentives` sum — **no change to `compute_salary` itself** beyond the
F-01 zero-floor already shipped 2026-10-29.

---

## 5. Build order — smallest first release

**Release 0 (no build):** tell the client new-installation amounts already work — point them at Masters → Installation
Rates and have them type real ₹ figures in. Confirm whether to switch off the old flat-threshold `installation`
Incentive Rule so it doesn't stack.

**Release 1 (smallest real slice): Sales Incentive % per product.** Pure additive table + match function (literal
clone of `installation_incentive_rates`/`installation_rate_for`) + one new `compute_incentives` block + one master
screen. No new attribution problem if scoped to the same "whoever's `technicians` row matches `invoices.sold_by`"
convention `sales_income` already (narrowly) uses — ship with that known limitation, documented, rather than
redesigning attribution first (see open question 1 in §7, which determines if this needs to be Release 1 or a later,
bigger release).

**Release 2: Warranty / AMC fixed visit amounts.** Needs the classification decision (§2.3) resolved first — once
resolved, this is small: one 4-row rate table, one `compute_incentives` block, one master screen.

**Release 3: Service referral %.** Needs the `referral_commission_events` table + approval workflow + the
read-only hook into the other window's lead/ticket plumbing. Build only after confirming with that other window's
owner that `leads`/`service_tickets.lead_id` is stable to read from (not mid-migration) — coordinate, don't guess.

**Release 4: AMC referral tiers.** Builds on Release 3's referral-event plumbing (AMC referrals are a subset of
"referred sales"); do this last since it depends on the tiering/counting-basis decision in §7 and on Release 3's
event table existing.

---

## 6. Risks / non-obvious consequences

- **Sales attribution is the real architectural fork.** `compute_incentives`/`compute_salary` are hard-wired to loop
  over `technicians`, not `profiles` generally (explicitly flagged as out-of-scope-to-redesign in
  `20260716140000_sales_income_attribution.sql`). If the client's sales staff are mostly non-technician `sales_admin`
  profiles (per `StaffSalaryTab.tsx`, which already exists precisely because non-technician staff never go through
  `compute_salary`), a per-product sales % needs either (a) extending the incentive engine to non-technician staff
  (bigger, touches the salary pipeline's core shape) or (b) accepting it only ever pays technician-flagged
  salespeople (smaller, matches existing `sales_income` limitation). This must be answered before Release 1 is sized.
- **Warranty/AMC visits are currently ₹0-revenue by hard policy** (v2.2 §6.2/6.3) — any future "% of revenue" idea
  for these visit types is a non-starter by design; the fixed-₹ approach the client already asked for is the only
  one that can work without reversing that policy.
- **`compute_salary` has no `is_active` check** (F-02, fixed separately for salary 2026-10-29, but every new block
  above must independently filter `is_active` technicians in its own loop, the same `and is_active` already present
  in `compute_incentives`'s existing loops — easy to forget on a new block, as the bike-allowance block shows it
  remembered).
- **Never trust a "rehearsed" DB change here without independent re-verification** — see
  `gv_mart_rehearsal_rollback_leak_2026_10_29` memory: a rollback-wrapped live preview on this exact incentive
  pipeline silently left real rows in prod once already.

---

## 6b. Release 1 design baseline — `compute_incentives` live-body pin (2026-11-02)

Read-only, via `run_rehearsal.mjs` against the Management API `database/query` route (not REST, not the
direct DB host) — the one approved channel for a live read against this project. Guard-checked
`--check-only` first (pure `select`, no write/DDL signal, passed with no RAISE needed), then sent.

- **sha256:** `07f7624b1233bf07b47474215210ca45212e6f5d172fb1421aaf285957eda89e`
- **length:** 16502 characters
- Sanity-checked against the body read earlier from branch `feat/referral-incentives` commit `a8682f6`
  (`20261202100001_referral_bonus_compute_and_report.sql`) — contains the referral block
  (`referral_bonus_events`, `v_ref_locked_count`) and the bike-allowance block (`is_bike_allowance`), both
  present as expected.
- Full body saved at
  `_local_only/worktrees/GV_mart_referral_close/_local_only/reports/compute_incentives_live_body_2026-11-02.sql`
  (local-only, not committed).

**This is the design baseline only.** At build time, re-run the same pin, byte-diff the new sha256 against
`07f7624b1233bf07b47474215210ca45212e6f5d172fb1421aaf285957eda89e`, and if it differs, rebase the new sales
block onto whatever is live then — never build on today's reading without re-confirming it.

## 6c. Release 1 scope, revised (client decisions 2026-11-02)

- **(a)** Partial returns reverse proportionally (not whole-line).
- **(b) Release 1 is now:** dated `sales_incentive_rates` (effective-dated, no-overlap, invoice-date resolver)
  + per-line `sales_incentive_credits` (snapshotted once, never recomputed) + master `void_sales_incentive_credit`
  (reason required, audited, refuses if locked) + a **read-only** "returns on commissioned lines" list for the
  master (surfaces every `returns` row with `status='completed'` matching an active, un-voided credit's line, so
  the master can decide/void manually). **The automatic returns clawback (system-triggered void-if-open /
  negative-credit-if-locked) is deferred to Release 2** — not built in Release 1.
- **(c)** Done — see §6b above.
- **Still blocking any build:** the client's answer to §6/§1's seller-vs-referrer question. Nothing is built
  until that answer arrives and the owner sends an explicit go-ahead.

## 6d. Release 1 — REVISED to the referrer variant (client answer 2026-11-02)

Client answered the §1 fork: the percent goes **only to the technician who referred the customer**; the
seller gets nothing from it. This changes Release 1's shape substantially — it is now an extension of
`referral_bonus_*`'s own cardinality (one payout per customer, ever), not a per-line seller commission.

### Removed from scope (no longer relevant)
- Technician-flagged-seller attribution (`invoices.sold_by → technicians.profile_id`) — gone; the referrer,
  not the seller, is who gets paid.
- The `sales_income` flat-rule double-pay guard and same-day cutover (§4 Q2 from the original plan) — **moot**.
  `sales_income` pays off a technician's own `technician_attributed_sales` (their own sales as a *seller*); my
  mechanism now pays a completely different role (*referrer*) off a completely different event (the customer's
  first qualifying sale). No shared event, no shared role, nothing to guard against between these two.

### Still relevant, carried forward unchanged
- Dated rates: effective-dated, no-overlap exclusion, resolver keyed to the **qualifying invoice's own date**,
  same validation (`effective_from` ≥ first day of current IST month, never inside an already-locked month).
- Snapshot-once / void-replaces-recompute discipline.
- Base amount = ex-GST, after line discount (`invoice_items.price × qty − invoice_items.discount`) — confirmed
  by the client, unchanged.
- The read-only "returns on commissioned lines" master list (Release 1, per the prior revision) — scope
  adjusted below, still in.
- Build-time re-pin rule, now covering **two** shared objects (see below).
- Real-role rehearsals.
- **Still live and unaffected:** the `finder_credit` vs. `referral_bonus_*` legacy-lead-fallback overlap flagged
  two turns ago. My mechanism inherits the exact same referrer-resolution path (`resolve_referrer_for_customer`),
  so it inherits that same overlap risk one-for-one — it is not a new risk my design introduces, and not
  something I can or should guard against here; it remains a decision for whoever owns both objects.

### Cardinality: owning the 'sale' source without editing any referral object

The live detector only ever looks at a customer's single, globally-earliest qualifying event
(`first_qualifying_event_for_customer` — one `UNION ALL ... ORDER BY qualified_at ASC LIMIT 1`, deterministic,
never reconsiders a later event once an earlier one exists) and only writes a `referral_bonus_events` row if
that specific event's source has a rate in force. If the master leaves (or clears) the `'sale'` row in
`referral_bonus_rates`, the live block permanently does nothing for any customer whose earliest event is a
sale — it is re-evaluated every run and always reaches the same "no rate → no event" `continue`, forever. That
gap is exactly what a new, additive block can own, reading only the two existing, unedited helper functions:

```sql
-- Appended strictly AFTER the live referral block in the same compute_incentives body (ordering matters —
-- see "what happens" below). Reads only; writes only to NEW tables.
for v_cust in
  select c.id as customer_id
  from public.customers c
  where c.org_id = p_org_id and not c.is_test
    -- READ-ONLY check against the live table — never written to.
    and not exists (select 1 from public.referral_bonus_events e where e.customer_id = c.id)
    -- my own one-per-customer-ever bookkeeping, same shape, a different table
    and not exists (select 1 from public.sales_referral_credits sc where sc.customer_id = c.id)
loop
  select * into v_resolved from public.resolve_referrer_for_customer(v_cust.customer_id); -- READ-ONLY call
  if v_resolved.referred_by_user_id is null then continue; end if;                 -- no referrer -> no payout
  if v_resolved.referrer_technician_id is null then continue; end if;              -- staff referrer -> existing manual path, not mine
  if not exists (select 1 from public.technicians t where t.id = v_resolved.referrer_technician_id and t.is_active) then continue; end if;

  select * into v_qual from public.first_qualifying_event_for_customer(v_cust.customer_id); -- READ-ONLY call
  if v_qual.qualified_at is null then continue; end if;
  if v_qual.qualified_at < v_resolved.referred_at then continue; end if;           -- same pre-referral rule as the live block
  if v_qual.source <> 'sale' then continue; end if;                               -- service/amc stay with the live flat mechanism
  if date_trunc('month', v_qual.qualified_at at time zone 'Asia/Kolkata') <> v_period then continue; end if;

  -- v_qual.qualifying_ref_id IS THE INVOICE ID for source='sale' (confirmed from
  -- first_qualifying_event_for_customer's own body) — sum the % across every line of THAT ONE invoice,
  -- each resolved against sales_referral_rates as of the invoice's own date, ex-GST, after line discount.
  -- (per-line detail written to a child table for audit; parent row is what feeds incentives_earned)
  ...
end loop;
```

**What happens to a customer whose first qualifying event is service/AMC (flat) while a later sale exists —
precisely:** the moment the live block (running earlier in the same function body, same transaction) inserts a
`referral_bonus_events` row for that customer's earlier service/AMC event, my block's very first `not exists`
check excludes them, permanently, on every future run. Their later sale is **never evaluated** by my block at
all. **No double payment** — the referrer was already correctly paid for the customer's actual first qualifying
event. **No gap** either, because this isn't a new restriction I'm inventing: the live system already denies a
second payout for *any* second event, sale or otherwise, under its own one-per-customer-ever rule — a sale
happening second is treated exactly the same as a second AMC or second service would be. The ordering
requirement (my block strictly after the live referral block, same transaction) is what makes the `not exists`
check see the live block's own inserts from this same run — this must hold at build time, re-verified by reading
the full live body, not assumed.

If a customer's first-ever event genuinely is the sale (because the master left `'sale'` rate-less), and no
rate in `sales_referral_rates` matches any line of that qualifying invoice either, the block writes nothing —
same "no rate → no event" convention as the live table, visible as a gap only in a future equivalent of
`count_referrals_pending_rate` (not built in Release 1 — out of scope, noted for Release 2 if wanted).

### Revised data model

```sql
create table public.sales_referral_rates (        -- dated, per product/category, unchanged shape
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid references public.products(id) on delete cascade,
  category public.brand_category,
  percent numeric(5,2) not null check (percent > 0 and percent <= 100),
  effective_from date not null,
  effective_to date,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (product_id is not null or category is not null),
  constraint sales_referral_rates_date_order check (effective_to is null or effective_to >= effective_from)
  -- + the same btree_gist no-overlap exclusion as referral_bonus_rates/the prior sales_incentive_rates draft
);
-- set_sales_referral_rate(p_org_id, p_product_id, p_category, p_percent, p_effective_from) — same 3
-- validations as set_referral_bonus_rate/set_sales_incentive_rate (month-start floor, no locked-month edits,
-- half-open close-and-insert on same-day edit).
-- sales_referral_rate_for(org_id, product_id, as_of date) — same most-specific-wins resolver.

create table public.sales_referral_credits (       -- ONE row per referred customer, ever (was per invoice line)
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  referrer_technician_id uuid not null references public.technicians(id) on delete cascade,
  qualifying_invoice_id uuid not null references public.invoices(id) on delete restrict,
  qualified_at timestamptz not null,
  commission_amount numeric(12,2) not null check (commission_amount >= 0),
  status text not null default 'active' check (status in ('active', 'voided')),
  voided_at timestamptz, voided_by uuid references auth.users(id), void_reason text,
  period date not null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (org_id, customer_id)   -- mirrors referral_bonus_events' own one-per-customer-ever constraint, in MY table
);

create table public.sales_referral_credit_lines (  -- per-line audit breakdown feeding the parent's amount
  id uuid primary key default gen_random_uuid(),
  credit_id uuid not null references public.sales_referral_credits(id) on delete cascade,
  invoice_item_id uuid not null references public.invoice_items(id),
  product_id uuid references public.products(id),
  rate_id uuid references public.sales_referral_rates(id) on delete set null,
  percent_applied numeric(5,2) not null,
  line_base_amount numeric(12,2) not null,
  line_commission numeric(12,2) not null
);

-- incentives_earned: reuse the existing credit_source bucket (installation_ticket already lives here),
-- widen its check to also accept 'sales_referral'. No change to the 5-way one-source CHECK's shape at all —
-- credit_source already counts as exactly 1 term regardless of which string it holds.
alter table public.incentives_earned drop constraint ...; -- re-pinned exact text, see build-time rule
alter table public.incentives_earned add constraint ...
  check (credit_source is null or credit_source in ('installation_ticket', 'sales_referral'));
```

One `incentives_earned` row per technician+period, summing `sales_referral_credits.commission_amount` where
`status = 'active'`, `credit_source = 'sales_referral'` — same locked-period skip-and-count idiom as every
other live block.

**Master void path:** `void_sales_referral_credit(p_credit_id, p_reason)` — same shape as before (master-only,
reason required, audited, refuses if the technician+period salary is locked).

**Returns list, rescoped:** surfaces any `returns` row (`status='completed'`) matching an `item_type`/`item_id`
on a `sales_referral_credit_lines` row whose parent credit is still `active` — read-only, master decides/voids
manually. Automatic clawback remains deferred to Release 2, unchanged from the prior revision.

### Build-time rule, reinforced — now two shared objects to re-pin
1. `compute_incentives` — re-pin via `pg_get_functiondef`, byte-diff against the baseline in §6b
   (`07f7624b1233bf07b47474215210ca45212e6f5d172fb1421aaf285957eda89e`), rebase if different.
2. `incentives_earned`'s `credit_source` check — re-pin its exact live definition the same way package 1 itself
   verified the 5-way `incentives_earned_one_source` check before widening it; refuse to proceed on a mismatch
   rather than blindly altering.
3. Every functional rehearsal step runs as the real `master`/`technician` role, through RLS, never as
   service-role/superuser (superuser steps stay limited to fingerprinting/schema inspection).

### Referral-package objects read — confirmed nothing written
**Read-only, unedited, called/selected exactly as they exist today:**
- `public.resolve_referrer_for_customer(uuid)` — called.
- `public.first_qualifying_event_for_customer(uuid)` — called.
- `public.referral_bonus_events` — `select`/`not exists` only; never inserted, updated, or deleted.
- `public.customers.referred_by_user_id` / `.referred_at` — read only, indirectly via the function above.
- `public.technicians.is_active` — not a referral object, read as every other block already does.

**Not touched at all, not even read:** `public.referral_bonus_rates` (the master's own choice to clear the
`'sale'` row is what the *live* block reads — my block has zero dependency on this table's contents),
`public.leads.referred_by_user_id`, `public.customer_has_qualifying_history`, `set_referral_bonus_rate`,
`correct_referral_attribution`, `void_referral_event`, `list_active_referrers`, `count_referrals_pending_rate`,
`referral_bonus_report`, `referral_bonus_preview`, `_referral_bonus_rows`. None of the 4b/package-5/ui-forms
work the referral window is mid-flight on is touched, read, or depended on by this design.

### One remaining question for the client

**Does the referral percent pay on the customer's first qualifying purchase only, or on every purchase they
ever make?** This whole design (one-per-customer-ever, mirroring `referral_bonus_*`'s own cardinality) is built
against "first only." **Recommendation: first only.** It matches the live package's existing, already-approved
cardinality exactly (no new compensation precedent to explain or defend), keeps the liability bounded and
predictable, and avoids an open-ended recurring revenue-share obligation that would need its own, much larger
design (per-sale detection instead of per-customer, a very different risk/complexity shape) if the client later
wants it. "Every purchase" is still buildable later as a different release if the client specifically wants it
— but it is a materially different mechanism, not a variant of this one.

## 7. Open questions the client must answer before any build starts

1. **Sales incentive attribution**: does the % apply only to technicians who also do sales (today's narrow
   `sales_income` behaviour), or to any staff member who sells (needs an engine change)?
2. **AMC referral tiers**: tiered by **count** of referrals in the period, or by **cumulative AMC sale value**
   referred? ("2, 3, 4 and so on" reads like count-based tiers, but needs confirming.)
3. **Warranty/AMC visit classification**: can "filter/spun-change only" be read off the spares used on the visit
   (if the spares catalog cleanly tags filter parts), or does the technician need to explicitly mark it at visit
   completion?
4. **Service referral**: earned when the referred sale is **won**, or only when the referred **ticket completes**
   (the existing `finder_credit` convention, which the client may want to match or deliberately diverge from)?
5. **Misuse checkpoint**: is master approval required on **every** referral commission event (slower, safest), or
   only above some ₹ threshold (faster for small ones, matches nothing else in the codebase today — every existing
   per-event incentive, like installation credits, requires 100% master approval, no threshold)?
6. **AMC referral tiers scope**: does an AMC sold **on-site by the referring technician themself**
   (`sell_amc_plan_onsite`, today tagged `source='field'`, not `'referral'`) count toward tiers, same open question
   `plan-referral.md` already raised and left unanswered for the finder-credit mechanism?
7. **Freeze semantics**: is "frozen at month-end" satisfied by the existing posted-salary lock (nothing pays
   differently once a technician's salary for that month is posted), or does the client want a separate, earlier
   cutoff (e.g. referrals/sales after the 28th roll to next month regardless of posting date)?
8. **New-installation Release 0**: can the old flat-threshold `installation` Incentive Rule be turned off now that
   per-product amounts are available, or does the client want both to keep stacking?
