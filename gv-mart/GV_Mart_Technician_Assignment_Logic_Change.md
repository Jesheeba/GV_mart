# GV Mart — Technician Assignment Logic Change Spec

**For:** Claude Code implementation
**Scope:** Rework the technician auto-assignment engine and supporting flow.
**Authority:** Client-signed Requirement Confirmation v2.2 + owner (Ramesh) clarifications captured in first meeting.
**Method:** Phased. Each phase has a static verification gate. Do not start a phase until the previous one passes. Do not add scope beyond what is listed.

---

## 0. Current state (what exists today)

The assignment engine lives entirely in Postgres/Supabase SQL, not the frontend.

- **Core engine:** `public._auto_assign_ticket_internal(p_ticket_id, p_org_id, p_skip_rating_logic)` — final definition in `supabase/migrations/20260715215000_assigned_at_sla_and_rating_reassignment.sql` (lines ~53–195).
- **Manual assign:** `public.assign_ticket_technician(appointment_id, technician_id, force)` — same migration (~lines 687–789).
- **Client entry points:** `src/services/service.ts` → `autoAssignTicket()`, `assignTicketTechnician()`; wrapped by `src/hooks/useService.ts`.
- **Call sites:** `auto_assign_ticket()` (role-gated), `create_complaint_ticket()`, `book_service_ticket()` (customer self-booking), AMC sell/renew paths, warranty QR registration.

**What the engine does now:**
1. Preconditions — ticket has an open appointment with no technician.
2. Rating override — prior job ≥4★ → same tech; ≤3★ → highest-rated other tech.
3. Default ranking — on-duty + currently-free techs, ordered by nearest last-known GPS, then fewest appointments that day, then oldest technician record.
4. No candidate → notify `operation_admin` for manual assignment.
5. Candidate → set `technician_id`, ticket → `assigned`, reset SLA, notify technician.

**What is missing today (this spec adds it):**
- No skill matching (`technicians.skills` exists, never read).
- No zone filtering (`technicians.zone` exists, never read).
- No spare-in-bag check at assignment time.
- No capacity/daily-ceiling limit per technician.
- No customer-availability-window handling in ordering.
- No late-binding for future jobs / no morning reconciliation after attendance.
- No live re-sequencing when a job overruns or a tech drops.
- `leads.owner_id` is never set or read → enquiry-finder incentive cannot be paid.
- Two correctness bugs in `create_sale` (see Phase 0).

---

## Phase 0 — Fix existing bugs (correctness, do this first)

These are broken regardless of the new design. Fix before building on top.

### 0.1 `create_sale` AMC auto-assign inconsistency
- Live path is the **5-arg overload** `create_sale(uuid,uuid,jsonb,uuid,integer)` (body in `20260716140000_sales_income_attribution.sql`, ~line 452).
- At ~line 711 the AMC add-on calls `_auto_assign_ticket_internal(v_amc_ticket_id, p_org_id)` **without** `p_skip_rating_logic => true`.
- **Fix:** add `p_skip_rating_logic => true` so POS-sold AMC visits behave like `sell_amc_plan` / `renew_amc_plan` (AMC visits are not standard rating-reassignment candidates).

### 0.2 Warranty scheduled visits never fire in production
- Quarterly warranty-visit scheduling was only added to the **dead 4-arg** `create_sale` overload. The live 5-arg body has no warranty-visit logic.
- **Fix:** port the "Warranty scheduled service" logic (every 3 months from first service date) into the live 5-arg `create_sale` per-product warranty branch. Keep the `register_product_via_qr` path as-is.

**Verification gate 0:** Sell an AMC via POS → AMC visit assigned with rating logic skipped. Sell a warrantied product via POS → quarterly warranty visits appear on the schedule.

---

## Phase 1 — Turn on the data the engine needs

No behaviour change yet; just make the inputs real and populated.

### 1.1 Skill
- Ensure `technicians.skills text[]` is populated (product competency: RO / AC / Inverter / Battery).
- Add `service_tickets.required_skill` (derived from product type on ticket creation).

### 1.2 Zone
- Ensure `technicians.zone` is authoritative (each tech assigned a zone).
- Ensure ticket carries a resolved `zone` (from address PIN → zone mapping).

### 1.3 Capacity
- Add `technicians.daily_capacity` (max jobs OR max minutes per day — pick minutes if SOP durations exist).
- Add `service_tickets.estimated_duration` sourced from the SOP-time master per job type.

### 1.4 Roster / leave
- New table `technician_availability` (technician_id, date, status: working/leave, optional shift window).
- This is separate from `is_on_duty` (which is *today's attendance only*). Roster is for future planning.

### 1.5 Customer availability window
- Ensure the appointment carries a real **time window** (not just free-text). Fields: `available_from`, `available_to`, or `mode = always`.

**Verification gate 1:** All five inputs exist, are populated for seed data, and are readable by a test query. No assignment behaviour changed yet.

---

## Phase 2 — Hard filter: skill + zone + part + capacity

Rework the **candidate filter** inside `_auto_assign_ticket_internal` (default ranking block, ~lines 137–162). Before ranking, filter the candidate pool to technicians that satisfy ALL of:

1. `org_id` match (existing)
2. Available (roster for future date; `is_on_duty` for same-day) 
3. **Zone match** — technician.zone = ticket.zone
4. **Skill match** — ticket.required_skill is in technician.skills
5. **Spare-in-bag** — technician's spare bag carries the part(s) the job needs (this is also the signed "bill can't close without the part" rule, moved earlier to prevent wasted trips)
6. No other open appointment (existing `for update ... skip locked` + not-exists)
7. Not over `daily_capacity`

If the filter empties the pool → keep existing behaviour: notify `operation_admin`, return `noneAvailable`.

**Verification gate 2:** An RO job never assigns to an AC-only tech. An out-of-zone tech is never picked. A tech at daily capacity is skipped. A tech missing the part is skipped.

---

## Phase 3 — Ranking: distance-first, with fairness and preference

Replace the current rigid rating-override cascade with a **weighted score** over the filtered pool. Order of influence:

1. **Least distance from technician's current/last location to the job** — this is Ramesh's core rule (nearest wins).
2. **Preference tilt** (soft, only if free + in-zone):
   - Customer's prior 4–5★ technician (continuity), OR
   - The enquiry-finder for a finder-sourced ticket.
3. **Fairness tiebreak** — if two candidates are effectively equal on distance, pick the **less-loaded** technician (fewest jobs/minutes that day).
4. **Quality steer** — prior job ≤3★ → de-prioritise that same technician, prefer higher average rating.
5. **Deterministic fallback** — oldest `technicians.created_at`.

Rules:
- Preference **never overrides distance when the preferred tech is far.** Far preferred tech → nearest free tech takes the job.
- Preference **never exceeds daily capacity.** Full preferred tech → someone else.

**Verification gate 3:** Nearest free tech is chosen by default. A loved/finder tech who is nearby+free is chosen over a stranger. A loved/finder tech who is far or full is skipped and the nearest free tech is chosen. Two equidistant techs → the less-loaded one wins.

---

## Phase 4 — Customer availability affects ordering

When sequencing a technician's day (next-job selection):

- Default next job = nearest remaining job in the technician's zone (Phase 3).
- **But** if the nearest job's customer window is not open at the projected arrival time, skip it and take the **next-closest job whose window IS open**, then return to the skipped job later once its window opens.
- Example: at A, B is nearest but customer unavailable at 5 PM → go A → C → back to B.

This requires `estimated_duration` (Phase 1.3) so projected arrival times are real, not guesses.

**Verification gate 4:** Given jobs B (nearest, window closed at arrival) and C (next, window open), the route orders A → C → B.

---

## Phase 5 — Enquiry-finder credit + assignment (Situation 1)

### 5.1 Credit (always-on, hard rule)
- Set `leads.owner_id` = the technician who logged the field enquiry, at creation time (currently never set).
- Read `leads.owner_id` into the incentive calculation so the finder is paid when the lead converts — **regardless of who services the job.**

### 5.2 Assignment (soft preference)
- When a finder-sourced enquiry converts to a job, prefer the finder in Phase 3 step 2.
- Finder nearby + free → finder does it.
- Finder far or full → nearest free tech does it. **Finder still keeps the credit/bonus.**

**Verification gate 5:** Finder is recorded on every field enquiry. Finder is paid on conversion even when another tech does the job. Finder gets the job when nearby+free; nearest tech gets it when finder is far.

---

## Phase 6 — Late-binding + morning reconciliation (absence safety)

### 6.1 Late-binding
- For **future-dated** appointments, reserve the slot (zone + window capacity) but **do not bind a named technician at booking.**
- Same-day / immediate jobs bind now as today.

### 6.2 Morning reconciliation (runs after the 9:15 attendance cutoff)
- For every reserved-but-unbound job dated today, run Phase 2–3 against technicians **actually present** (attendance confirmed).
- If the originally-planned tech is absent, the job flows to another present, eligible tech (this is the fix to "flow continues as planned" — the plan continues, but absent techs' jobs re-flow to present techs, never left on a ghost).
- If an entire zone has no present coverage → flag those customers for early reschedule + auto-notify.

### 6.3 Confirmation call
- Keep the signed confirmation-call-before-dispatch as the final human checkpoint after reconciliation.

**Verification gate 6:** A future job holds a slot but no name until the morning. An absent tech's jobs are reassigned to present techs at reconciliation. A fully-uncovered zone raises reschedule notifications.

---

## Phase 7 — Live re-sequencing + carry-over

### 7.1 Re-sequence triggers
Re-run the day's route for a technician when:
- A job overruns its SOP time (timer goes red),
- A tech goes offline / becomes unavailable mid-day,
- An urgent job lands mid-day.

On re-sequence, auto-notify affected customers a new ETA (WhatsApp).

### 7.2 Carry-over
- Jobs a technician could not complete today → marked **first priority for the next date** (ties into the signed daily to-do carry-forward).
- Distinguish reason: "ran out of time" vs "customer not home" (may need different handling — confirm with owner).

**Verification gate 7:** An overrun re-sequences remaining stops and notifies. Uncompleted jobs appear top-priority next day.

---

## Global rules that must always hold (assert in tests)

- One open appointment per technician at a time.
- One open appointment per customer at a time.
- No technician assigned beyond `daily_capacity`.
- Priority order: very urgent → urgent → normal; repeat/urgent callers bumped up a tier.
- Manual admin assignment (`assign_ticket_technician`, with `force`) always available — reachable fast for the "customer complained, nobody came" case. Make manual override **auditable** (log who/why) and rate-limited.
- Assignment logic must be explainable ("assigned because: in-zone, free, nearest") — no black-box.

---

## Admin-side requirement (explicit)

Provide a fast manual-allocation path for the complaint case: a customer says they booked earlier and no technician visited. Admin can manually allocate/re-allocate a technician to that specific job from the ticket screen or the appointments board (drag-drop + force reassign already exist — ensure this exact scenario is one or two clicks, and that force-reassign is audited).

---

## Open decisions for the owner (do NOT hardcode — make these settings)

1. **"Too far" measured how** — by zone, or by a set distance/time threshold? (Recommend: by zone for v1.)
2. **Preferred tech is full** — give the job to another tech now (finder still paid), or hold for the preferred tech? (Recommend: reassign now.)
3. **Strength of the "same technician returns" pull** — gentle nudge vs strong hold.
4. **"Nearest" definition** — straight-line distance vs actual driving time (maps service). (Recommend: straight-line for v1, upgrade later.)
5. **Carry-over reason handling** — treat "ran out of time" and "customer not home" the same or differently?

Expose 1–4 as configurable master/settings values; default them per the recommendations above.

---

## Build order summary

Phase 0 (bugs) → 1 (data on) → 2 (hard filter) → 3 (ranking) → 4 (availability ordering) → 5 (finder credit + assign) → 6 (late-bind + reconciliation) → 7 (live re-sequence + carry-over).

Each phase shippable and testable on its own. Do not proceed past a failing verification gate.
