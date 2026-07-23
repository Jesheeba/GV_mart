# GV Mart — Build Order & Guardrails

**For:** Claude Code
**Purpose:** The running order for the current backlog, plus the rules for when to stop and ask. This file decides *sequence and scope*. The *what/how* of each item lives in the two companion specs — read them alongside this:
- `GV_Mart_Technician_Assignment_Logic_Change.md` (the assignment engine, Phases 0–7)
- `GV_Mart_Meeting_Changes_2026-07-20.md` (owner meeting changes, Sections A–H)

**When two specs disagree, the meeting-changes spec wins** (it's the most recent owner authority).

---

## How to work this file

Build strictly top to bottom. Do not skip ahead. Each step has a **Definition of Done** — do not mark a step done until it's met and verified.

Three hard rules that override any eagerness to build:

1. **STOP-AND-FLAG rule.** If an item is marked DECISION or PARKED below, do NOT build it. Stop and surface it to the user for a decision first. Building a DECISION item without the decision is a mistake, even if the code seems obvious.
2. **SCOPE-GUARD rule.** Two items (complaint-name master, exemption windows) were previously on the declined list but are now owner-authorized. Build those. For anything *else* that resembles a previously-declined item, stop and flag before building — do not assume authorization.
3. **VERIFY rule.** For any "settings-driven" or "already built" item, prove it by changing the value/state and confirming behaviour changes. "The screen exists" is not "it works." A step isn't done until verified.

---

## STEP 1 — Fix the 3 live bugs (do first, today)

These are wrong data on screen right now. Quick, and independent of everything else.

1.1 **CustomerAmcPage.tsx** — plan-selection buttons show the old flat price while the total below computes `price_per_year × years`. Make the button price and the total use the same source. **Done when:** button price and total always agree.

1.2 **AmcWarrantyListPage.tsx** — the "renewal at risk ₹" stat sums the stale flat price. Switch it to `price_per_year`. **Done when:** the stat matches the real plan pricing.

1.3 **Bill-entry category** — every purchase bill is hardcoded to `category='purchase'` regardless of what was bought. Tag purchases with the actual category. **Done when:** a purchase bill carries its real category, and the P&L breakdown reflects it. (This also unblocks STEP 6 reports.)

**Definition of Done (Step 1):** all three fixed and visually confirmed on screen.

---

## STEP 2 — Make the assignment engine correct (Assignment spec Phase 2)

The engine currently sends nearest-technician with no guardrails. Add the hard filter BEFORE ranking. Per companion spec Phase 2.

Filter the candidate pool to technicians that satisfy ALL of:
- Zone match (ticket zone = technician zone)
- Capacity not exceeded (daily ceiling)
- Spare-in-bag (technician's bag carries the needed part)
- One-open-appointment (already enforced — keep)

**G1 CORRECTION — critical:** Do **NOT** gate on skill. The owner removed product specialization (all technicians handle RO/Inverter/Battery). Keep the `skills` column for the future, but skill is a no-op filter now. Do not let it block assignment.

**Definition of Done (Step 2):** an out-of-zone technician is never picked; a technician at capacity is skipped; a technician missing the part is skipped; skill never blocks anyone.

---

## STEP 3 — Add the ranking (Assignment spec Phase 3)

Once the filter exists, rank the surviving candidates. Per companion spec Phase 3.

Order of influence: nearest distance first → soft preference tilt (customer's prior 4–5★ technician, or the enquiry-finder) only if free + in-zone → fairness tiebreak (less-loaded technician) → quality steer (avoid prior ≤3★) → deterministic fallback.

Rules that always hold: preference never overrides distance when the preferred technician is far; preference never exceeds capacity.

**Definition of Done (Step 3):** nearest free technician chosen by default; a nearby+free loved/finder technician preferred over a stranger; a far/full preferred technician skipped; equidistant tie → less-loaded wins.

---

## STEP 4 — Build the owner's headline booking model (Meeting spec Section B)

This is the owner's stated main goal. Build it now that the engine underneath is correct.

4.1 **Date-only + unavailable-windows (B1):** customer picks a DATE only, then marks the windows they are NOT available. "Any time" opens the full working window with the working-hours pop-up.

4.2 **Narrow-availability guard (B2):** if the customer marks almost the whole day unavailable, treat the small remaining window like a specific-time booking and check capacity against it.

4.3 **Today-full → next-day-first-priority (B3):** if the chosen date is full, auto-schedule next day as first priority.

4.4 **Exemption windows (B4) — SCOPE-GUARD, authorized:** per-customer short unavailable windows shown red; no assignment during them. This was previously declined; owner now explicitly wants it — build it.

**Definition of Done (Step 4):** a customer can book by date + unavailable windows; a near-full day pushes to next-day-first-priority; exemption windows block assignment in their slots.

---

## STEP 5 — Wire availability into routing (Assignment spec Phase 4)

The `available_from/available_to` fields are currently written but never read. Now make the router read them.

Next-job = nearest remaining job in the technician's zone whose availability window is open at projected arrival; if the nearest job's window isn't open yet, take the next-closest open one and return later (A → C → back to B).

**Definition of Done (Step 5):** given a nearer job with a closed window and a farther job with an open window, the route orders the open one first and returns to the closed one when it opens.

---

## STEP 6 — Standalone wins (each independent; build in this order)

6.1 **History depth (Meeting spec D6):** the data (`service_visits.notes`) is already captured but never shown. Show the last 2 services (or the year), including parts-changed and the previous technician's notes. **Quick win.** **Done when:** the technician's history button shows past notes + parts, not just dates.

6.2 **Reports completion (Meeting spec F2):** date-range + GST toggle already work. Add month / previous-month / this-year / all-time presets and a category filter. Depends on Step 1.3 (category tagging) being fixed. **Done when:** choosing any filter returns correctly-categorized data.

6.3 **Finder credit payout (Assignment spec Phase 5):** `leads.owner_id` is now set and shown on the report, but never feeds an actual incentive payout. Wire it into the incentive calculation, and add the finder-preference to assignment (already covered by Step 3's tilt). **Done when:** the finder is credited on conversion regardless of who services the job.

6.4 **Complaint-name master (Meeting spec E1) — SCOPE-GUARD, authorized:** replace free-text with a product-tagged, admin-editable complaint-type master feeding a filtered auto-suggest dropdown (customer booking + admin complaint screen). Previously declined; owner now requests it — build it. **Done when:** typing filters to that product's complaint types, and admin can add a missing type.

6.5 **Job-screen fields (Meeting spec D5):** add the missing "additional contact" field; confirm tap-to-call, description, priority, history all present on the technician job screen.

---

## DO NOT BUILD — stop and flag first (DECISION items)

These need a locked decision. If you reach them, STOP and ask the user. Do not build.

- **OTP completion + fallback (Meeting spec D2 / Assignment context):** recommended three-tier (OTP → signature-on-technician-phone → photo marked "unverified"). Not re-verified in last pass. Decision required.
- **SOP checklist after before-photo (Meeting spec D4):** recommended data model = checklist populated from the job's inventory items (each carrying its standard time) vs a fixed pre-set list. Decision required before building the data model.
- **PO supplier selection / quotation (Meeting spec C3):** recommended = instant PO to last-known-cheapest + separate periodic price-refresh (not a live quote round in the stock-out path). Decision required. (C1 reorder formula and C2 approval toggle ARE build-ready — see below.)
- **Working-hours end time (Meeting spec A2):** confirm 7:00 / 7:30 / 6:30 before locking the single settings value.
- **Double-review concern (Meeting spec F1):** how to avoid app-review + Google-review showing twice. Decision required.

### Build-ready parts of the above (these you CAN build now)
- **C1 reorder formula:** per-spare max/min, order qty = max − current, seasonal levels. Build.
- **C2 PO approval toggle:** settings OFF = auto-send, ON = wait for admin approval. Build. (Only the *supplier-selection/quotation* part, C3, is the decision.)
- **A-section settings-wiring (A1 discount 2%/5%, A3 travel 2 min/km, A4 AMC tiers):** build/verify the wiring. These are VERIFY items, not decisions.

---

## DO NOT BUILD — parked for a later phase (Meeting spec Section H)

Do not touch these this pass, even if related work makes them tempting:
- WhatsApp product-enquiry flow (budget-band tree; Amazon-style AMC plans with video/voice/one-click).
- AI diagnostic troubleshooting steps (owner's trained step-by-step checklists).
- Salary / rewards / incentives (owner will provide by call).
- Product data / billing format / catalog (owner will send via Excel).

---

## Summary running order

1. 3 live bugs → 2. Engine filter (no skill gate) → 3. Engine ranking → 4. Date-only booking model → 5. Availability-aware routing → 6. Standalone wins (history, reports, finder payout, complaint master, job fields).

Build-ready alongside: C1, C2, A-section verify.
Stop-and-flag: OTP, SOP checklist, PO supplier, working-hours end time, double-review.
Never this pass: Section H.

Work smarter: fix the money bugs, make the engine *correct* before making the front door *pretty*, and never build a DECISION or previously-declined item without flagging first.
