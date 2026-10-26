# Monthly Expenses: Mobile Recharge and Bike Costs

**Status:** normative. Build to this document.
**Scope:** this feature only. Nothing else in the application changes.
**Date:** 21 October 2026

---

## 0. What this is, briefly

Technicians spend money doing their jobs — phone recharges, petrol, bike
servicing. Today none of that is tracked in the application, so none of it
reaches the monthly report and none of it reaches salary. It is settled
informally and invisibly.

This feature makes four monthly amounts first-class data:

| Item | Nature | Who it applies to |
|---|---|---|
| Mobile recharge allowance | reimbursement | anyone with an amount set |
| Bike petrol | reimbursement | all technicians |
| Bike maintenance | reimbursement | all technicians |
| Own-bike allowance | **incentive** | technicians on their own motorcycle |

Three of them are money the person already spent, paid back. The fourth is a
benefit for putting a personal motorcycle to company use, and it behaves
differently: it flows through the incentive calculation.

All four appear as separate itemised lines on the salary breakdown and as a
cost breakdown in the monthly report. Technicians submit photographs of bills
from their own screen; master and operational admin verify them and decide
what is actually paid.

**The non-negotiable bit:** nothing unverified reaches salary or the report,
every amount an admin changes carries a written reason, and the kilometre log
is append-only history that is never overwritten.

---

## 1. Decisions already made

These were settled with the business owner. Build to them. If one conflicts
with how this codebase actually works, **stop and say so** — do not bend the
codebase to fit, and do not quietly change the decision.

### 1.1 Mobile recharge

- A fixed monthly allowance, **set per person**. Not one organisation-wide
  figure.
- A person with no amount set receives nothing. **This is how scope is
  controlled** — there is no role rule to implement and no "is this person
  eligible" logic to write.
- An admin may add an amount **above** a person's allowance for a given month.
  A written reason is mandatory whenever they do.
- Reimbursement, not incentive.

### 1.2 Bike ownership

- Each technician is on either **their own motorcycle** or a **company
  motorcycle**.
- Recorded with **effective dates**, so a change part-way through a month is
  representable and auditable.
- Own bike earns the monthly allowance. Company bike does not.
- Both submit fuel and maintenance bills through the **same screen** and the
  **same verification flow**. Ownership changes only the allowance.

### 1.3 Petrol

- The payable figure is **kilometres travelled × that technician's rate per
  km**.
- The rate is **per technician**, because it tracks the mileage and condition
  of their particular bike. It must be editable.
- The technician's uploaded bill is **proof that the spend happened**. It does
  not set the figure.
- An admin may **override** the computed figure for a month. A written reason
  is mandatory when they do.
- Reimbursement. The salary line shows the kilometres, the rate and the result.

### 1.4 Maintenance

- The technician uploads a **photograph of the bill** and types the amount.
- Master or operational admin verifies it and sets the amount that will
  actually be paid, **which may differ from what the technician typed**.
- Only a verified amount reaches salary or the monthly report. An unverified
  submission reaches **neither**.
- **There is no separate rejected state.** An admin rejecting a claim verifies
  it at zero, and the reason field records why. Nothing is deleted.
- Reimbursement.

### 1.5 Kilometres

- A **log**, not a single stored figure. Entries accumulate and are **never
  overwritten**.
- Each entry carries its own date, the kilometres, who added it, and when.
- Both the technician and an admin can add entries.
- Viewable filtered **by date range** and **by month**. Reuse the filter
  components this application already has rather than building new ones.
- Whatever approximate distance the application **already tracks** is displayed
  alongside the manual log for comparison. It does **not** replace it. **The
  manual log is what money is calculated from.**

### 1.6 Own-bike allowance

- One organisation-wide **base amount, defaulting to 1000**, editable by
  master.
- An admin may add an **extra** amount for a specific person, with a mandatory
  written reason.
- This one is an **incentive**. It must flow through `compute_incentives` into
  the monthly incentive total.
- **Pro-rate it** by the number of days in the month the technician was on
  their own bike.
- On the salary breakdown it appears as its own line showing the base amount,
  any extra, and the reason for the extra.

### 1.7 Exclusions

- An admin can **exclude a single month for one person**, **exclude a person
  entirely**, or **zero a single amount**.
- A reason is recorded on every exclusion.
- If this codebase already has an override or exclusion pattern, **match it**
  rather than inventing a second one.

### 1.8 Who does what

**Technician**
- upload a bill photograph and type an amount
- add kilometre entries
- view their own submissions and their own history
- see nothing belonging to anyone else

**Master and operational admin**
- verify submissions and set the paid amount
- set each person's recharge allowance
- set each technician's petrol rate
- assign bike ownership
- set the organisation base allowance
- add extras with reasons
- add exclusions

### 1.9 Where the money surfaces

1. **`compute_incentives`** — the own-bike allowance, and nothing else from
   this feature.
2. **`compute_salary`** — all four items as **separate itemised lines**. Never
   collapsed into a single figure.
3. **The monthly report** — per technician and organisation-wide, broken down
   by category.

---

## 2. Read the code before you design

Column names, table names and types in section 3 are **proposals**. Confirm
every one against what exists and rename to match local convention. Before
writing anything, establish:

1. **Distance tracking.** Does the application record distance travelled by a
   technician today? Which table, which column, how populated, what
   granularity, can it be summed per technician per calendar month, and is
   "approximate" computed somewhere.
2. **`compute_incentives`.** Full read. Signature, return shape, how a period
   is identified, every component contributing to the total, where
   `incentive_rules` is consulted, the permission guard, any audit trigger,
   what it writes and where, how the frontend invokes it.
3. **`compute_salary`.** Same. Plus: does the output already carry itemised
   lines or a single total, and is there any existing concept of an addition,
   deduction, reimbursement or allowance line.
4. **The monthly report.** SQL function, view, or frontend aggregation. Which
   file, which sections, where a per-technician cost breakdown belongs.
5. **The technician record.** Where a technician's own data lives, and whether
   any vehicle or asset data is already attached.
6. **Organisation settings.** How configurable numeric config is stored and
   edited, with a concrete existing example and the screen that edits it.
7. **File upload.** Does this application upload images anywhere today? Bucket,
   public or private, storage policies, how the key is built, where the
   reference is stored, the upload component, size and type limits, how the
   image is served back. **If nothing has ever been uploaded, say so** — that
   changes the size of unit 3 considerably.
8. **Submit-then-verify.** Anything today where one role submits and another
   approves. Status column, allowed transitions, who may perform each, whether
   rejected records are kept, whether the submitter is notified.
9. **Filters.** Existing date-range and single-month filter components, admin
   side and technician side, and how the filter reaches the query.
10. **Conventions.** The money column type and precision used elsewhere. The
    RLS pattern for an admin-write table. The RLS pattern for a table a
    technician inserts into but reads only their own rows from. How `audit_log`
    entries are produced for admin-entered values. **The current highest
    migration number** — report it, do not create a file.

---

## 3. Data model

Five new tables proposed. Confirm against local convention before creating.

### 3.1 `technician_vehicles`

Which bike a technician is on, and their petrol rate, over time.

| column | notes |
|---|---|
| `id` | pk |
| `org_id` | match the org pattern used elsewhere |
| `technician_id` | fk |
| `ownership` | `'own'` or `'company'` — constrained |
| `petrol_rate_per_km` | money precision as used elsewhere |
| `effective_from` | date, not null |
| `effective_to` | date, nullable; null means current |
| `created_by`, `created_at` | audit |

**Constraint:** no two rows for one technician may have overlapping effective
ranges. Enforce it in the database, not only in the UI.

**Why effective dates:** a technician who switches bikes on the 12th must
produce a pro-rated allowance for that month. A single `ownership` column on
the technician record cannot represent that and will silently pay the wrong
amount.

### 3.2 `technician_km_log`

Append-only. One row per entry.

| column | notes |
|---|---|
| `id` | pk |
| `org_id` | |
| `technician_id` | fk |
| `entry_date` | date, not null — the date travelled, not the date entered |
| `km` | numeric, positive |
| `note` | nullable free text |
| `entered_by` | who added it |
| `entered_at` | timestamptz |

**No update path.** A mistaken entry is corrected by adding a compensating
entry, not by editing. If local convention demands a soft-delete instead, say
so in your report rather than deciding alone.

### 3.3 `expense_claims`

Petrol and maintenance submissions with their bills.

| column | notes |
|---|---|
| `id` | pk |
| `org_id` | |
| `technician_id` | fk |
| `period_month` | first day of the month, or match the period convention `compute_salary` already uses |
| `claim_type` | `'petrol'` or `'maintenance'` — constrained |
| `submitted_amount` | what the technician typed |
| `bill_photo_path` | storage key |
| `submitted_at` | timestamptz |
| `verified_amount` | nullable. **Null means not yet verified** |
| `verified_by` | nullable fk |
| `verified_at` | nullable timestamptz |
| `reason` | nullable; **required when `verified_amount` differs from `submitted_amount`** |

**Enforce in the database:** a row where `verified_amount` differs from
`submitted_amount` and `reason` is null must be rejected. This rule is the
whole audit trail — if it lives only in the frontend it will be bypassed.

**`verified_amount IS NULL` is the gate.** Salary and the report read only
verified rows. This is simpler and safer than a status enum, and it means an
unverified claim cannot reach payroll through any code path.

### 3.4 `person_allowances`

Each person's standing monthly recharge allowance.

| column | notes |
|---|---|
| `id` | pk |
| `org_id` | |
| `profile_id` | the person — **not** restricted to technicians |
| `recharge_amount` | money precision as used elsewhere |
| `effective_from`, `effective_to` | so a change is auditable, same pattern as 3.1 |
| `created_by`, `created_at` | |

A person with no row here receives no recharge allowance. That is the intended
behaviour and the whole of the scoping rule.

### 3.5 `monthly_adjustments`

**One general mechanism** for every top-up, extra and exclusion. Do not build
three separate tables for these.

| column | notes |
|---|---|
| `id` | pk |
| `org_id` | |
| `profile_id` | the person |
| `period_month` | |
| `adjustment_target` | `'recharge'`, `'petrol'`, `'maintenance'`, `'bike_allowance'` |
| `adjustment_type` | `'top_up'` or `'exclude'` |
| `amount` | nullable — null for an exclusion |
| `reason` | **not null. Always.** |
| `created_by`, `created_at` | |

This covers: a recharge top-up above the allowance, an extra bike allowance, a
single month excluded for one person, and a single amount zeroed. Excluding a
person **entirely** is done by ending their `person_allowances` row and their
`technician_vehicles` row, not by a permanent adjustment row.

### 3.6 Organisation setting

The own-bike allowance base amount, default `1000`, editable by master. Put it
wherever organisation config already lives — do not create a new settings
mechanism for one number.

---

## 4. Build units

Build in this order. Each unit's tests are written **with** that unit, not
afterwards, and must pass before moving on.

### Unit 1 — Bike ownership and petrol rate

Table 3.1, its RLS, the admin screen to assign ownership and set the rate, and
a resolver that answers "which bike was this technician on, on this date" and
"how many days of this month were they on their own bike".

**Tests**
- overlapping effective ranges are rejected by the database
- current ownership resolves correctly for a technician with one row
- a technician who switched on the 12th of a 31-day month yields 11 days own
  and 20 days company — assert the exact day counts, including the boundary day
- a technician with no row resolves to no ownership and no rate, and nothing
  downstream crashes
- a technician cannot read or write this table

### Unit 2 — Kilometre log

Table 3.2, its RLS, technician entry, admin entry, the date-range and
month-filtered views reusing existing filter components, and the monthly sum.
Display whatever approximate distance the application already tracks beside the
log, clearly labelled as reference.

**Tests**
- entries accumulate; the monthly sum is the sum of entries
- there is no code path that updates or deletes an entry
- a technician reads only their own entries
- an entry dated outside the filtered range does not appear and does not count
- the monthly sum for a technician with no entries is zero, not null

### Unit 3 — Bill submission and verification

Table 3.3, its RLS, the storage bucket and its policies, the technician screen
(photograph plus amount), the admin verification screen (view the photograph,
set the paid amount, write the reason), and the database constraint from 3.3.

If this application has never uploaded a file, this unit is the largest in the
feature. Size it honestly and say so.

**Tests**
- a claim with `verified_amount` null is invisible to salary and to the report
- `verified_amount` differing from `submitted_amount` with a null reason is
  rejected by the database, not just by the form
- a verified amount of zero behaves as a rejection: nothing is paid, the row
  and the photograph survive, the reason is readable
- a technician cannot read another technician's claim or fetch their photograph
  by guessing the storage key
- the photograph is not publicly reachable without authentication
- oversized and non-image uploads are refused with a usable message

### Unit 4 — Allowances and adjustments

Tables 3.4 and 3.5, their RLS, the admin screens, and the organisation setting
from 3.6.

**Tests**
- a person with no `person_allowances` row receives no recharge
- a top-up with a null reason is rejected by the database
- an exclusion for one month affects that month only
- ending a person's allowance row stops future months without altering past
  ones
- an adjustment belonging to another organisation is not visible or applicable

### Unit 5 — Own-bike allowance into `compute_incentives`

Hook the pro-rated allowance into the incentive calculation. Quote the existing
code you change and show what replaces it.

**Tests**
- a technician on their own bike all month receives the full base amount
- a technician on a company bike all month receives nothing
- the mid-month switch from unit 1 produces the pro-rated amount; assert the
  exact rupee figure
- an extra with a reason adds on top, and the reason is retrievable
- **every existing component of the incentive total is unchanged.** Run the
  incentive calculation for a technician with no vehicle row and assert the
  result is byte-identical to what it was before this feature existed. This is
  the test that matters most in the whole feature.

### Unit 6 — Itemised lines in `compute_salary`

Four separate lines: recharge, petrol (with kilometres and rate shown),
maintenance, own-bike allowance (with base, extra and reason). Never collapsed.

**Tests**
- all four lines appear separately for a technician who has all four
- a technician with none of them produces salary output identical to before
- the petrol line shows the kilometres and the rate, not only the result
- the itemised lines sum to the totals the function reports
- an admin override is the figure that appears, not the computed one, and its
  reason is carried through
- if the return shape changed, the frontend renders the new shape correctly and
  no existing field silently disappeared

### Unit 7 — Monthly report

The per-technician and organisation-wide cost breakdown by category, in the
existing report rather than a new screen.

**Tests**
- report figures reconcile exactly with the salary lines for the same month
- unverified claims are absent from the report
- excluded amounts are absent
- the organisation total equals the sum of the per-technician figures

### Unit 8 — End to end

One month, one organisation, several technicians: one on their own bike all
month, one on a company bike, one who switched mid-month, one with an excluded
month, one with a top-up, one with a claim verified at a lower amount than
submitted, and one with no expenses at all.

Assert the salary breakdown and the monthly report for each, and assert that
the technician with no expenses is entirely unaffected by the feature.

---

## 5. Constraints

These are standing rules on this project. They are not negotiable and they
apply to every unit.

- **No database write of any kind against the live database** unless it is
  named explicitly and approved first. Building and testing happens locally or
  against a test harness.
- **Never pre-assign a migration number.** Confirm the current highest number
  at the moment of writing the file. Do not reserve one in advance and do not
  write a number into this document.
- **Never concatenate a migration with a test file** and run the result against
  the live database.
- Any destructive or irreversible step is **named before it runs**.
- Do not rewrite git history.
- `SECURITY DEFINER` functions pin `search_path`.
- Use `set local`, never session-level settings over a pooled connection.
- Every admin-entered amount produces an `audit_log` entry following the
  existing pattern.

---

## 6. Done means

- All eight units built, with their tests passing.
- `compute_incentives` and `compute_salary` produce **identical output** to
  before this feature for any technician who has no data in it. Demonstrated,
  not asserted.
- Nothing unverified can reach salary or the report through any code path.
- Every amount an admin changed carries a readable reason.
- No kilometre entry can be altered after the fact.
- A technician can see their own submissions and history, filtered by date and
  by month, and cannot see anyone else's.
- Migrations written and reviewed, but **not applied** to the live database —
  applying them is a separate, named, approved step.

---

## 7. Report back

When the build is done, report:

- what you changed in `compute_incentives` and `compute_salary`, quoting before
  and after
- the migration files in the order they must run
- anything in section 1 that did not fit this codebase, and what you did
  instead
- anything you could not test, and why
- the storage decisions, if this application had never uploaded a file before
- what you would want a second pair of eyes on before these migrations go near
  the live database
