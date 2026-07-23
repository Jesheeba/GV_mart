# GV Mart — Change Spec from Owner Meeting (20 July 2026)

**For:** Claude Code implementation
**Source:** Requirement meeting with owner (Ramesh), 20 Jul 2026 + confirmations by Sirah Digital.
**Authority order:** This meeting supersedes earlier drafts where they conflict. Signed v2.2 remains the base; items below are corrections/additions/decisions on top of it.
**Method:** Phased. Each item marked CONFIRMED is ready to build. Items marked DECISION need a choice locked first (recommendation given). Items marked PARKED are out of this build. Items marked SCOPE-GUARD were previously on the declined list but are now client-requested — treat as authorized change requests.

**Global principle for this spec:** Wherever an item says "settings-driven," the admin settings value MUST be the live value the engine reads — not a hardcoded constant with a settings screen that does nothing. Every settings-driven item has a verification step: change the value in settings, confirm app behaviour changes.

---

## SECTION A — Corrections to already-documented values (settings-wiring)

These behaviours are already built. The task is to confirm each reads from the admin settings page, not from a constant. Do NOT change the numbers in code — make them editable and wired.

### A1. Discount limits — CONFIRMED (settings-driven)
- New values from owner: technician up to **2%** without approval, admin up to **5%**, above **5% blocked entirely**. (Was 5%/10% in v2.2.)
- Do not hardcode. Wire the technician ceiling, admin ceiling, and hard block to settings values.
- **Verify:** change ceilings in settings → invoice screen enforces the new limits.

### A2. Working hours — CONFIRMED (settings-driven)
- Technician working hours are admin-editable. Owner quoted 9 AM–7 PM (customer window elsewhere quoted 9 AM–6:30 PM). Do not hardcode either — read from settings.
- **Verify:** change hours in settings → booking window and technician day reflect it.
- **Open value to confirm with owner:** exact end time (7:00 vs 7:30 vs 6:30). Until confirmed, keep it a single settings value used everywhere.

### A3. Travel time — CONFIRMED (settings-driven)
- Default **2 min/km** (was mistakenly 5 in earlier docs), editable per region from settings (owner: Bangalore may need 5).
- **Verify:** the green/red distance-reach indicator uses the settings value, not a constant.

### A4. AMC tiers — CONFIRMED (already dynamic)
- Now four tiers: Gold / Silver / Platinum / **Platinum Plus**. Admin can add more.
- No code change — confirm the AMC master supports adding/editing tiers freely.

---

## SECTION B — Customer booking model change (CONFIRMED, build)

This replaces exact-time booking. This is the main conflict-reduction change.

### B1. Date-only + unavailable-windows booking
- Customer picks a **DATE only** (e.g. 21.07.2026), NOT a specific arrival time.
- Customer then marks the time windows they are **UNavailable** at home (e.g. "not 1–2 PM, school run"). Those windows turn red; no job is assigned to that customer in a red window.
- "Any time" = full working-hours window open (show a pop-up: "Our technicians work 9 AM–[X] PM; technician will arrive within this window").
- This maximises router flexibility (customer bounds the day instead of dictating a minute).

### B2. Narrow-availability edge case — build this guard
- If a customer marks almost the whole day unavailable (e.g. only a 30-min window left), treat that residual window like a **specific-time booking** and check capacity against it. Do not let it silently overbook.

### B3. Today-full → next-day-first-priority — CONFIRMED
- If the chosen date is fully booked, auto-schedule to the next day as **first priority**. (Matches carry-over rule.)

### B4. Exemption windows — SCOPE-GUARD (now authorized)
- Per-customer short unavailable windows (school run, medical) shown as red on the technician/scheduling view; no assignment during them even if a technician is free.
- This was previously on the declined "availability-exception windows" list. Owner walked through it in detail and explicitly wants it → **authorized change request, build it.**

---

## SECTION C — Inventory, PO, and supplier (CONFIRMED formula, DECISION on quotation)

### C1. Reorder formula — CONFIRMED
- Per **spare part** (not per product): admin sets **max stock** and **min stock**.
- When current stock hits **min** → auto-trigger. **Order quantity = max − current level.** (e.g. max 100, min 10, hits 10 → order 90.)
- Support **seasonal stock levels** (different max/min by season).

### C2. PO approval toggle — CONFIRMED
- Settings toggle: **OFF = PO auto-sends** to supplier; **ON = PO waits for admin approval** before sending.

### C3. Supplier selection + quotation — DECISION NEEDED
- Owner wants: PO goes to the supplier offering the lowest price for that product/spare, based on previous bills; ideally the system requests quotes from all suppliers and picks the lowest.
- **Problem:** a live "ask everyone to quote, then pick lowest" round takes time (suppliers don't reply instantly) and can cause a **stock-out while waiting** — which defeats auto-PO.
- **RECOMMENDED default (build this unless owner overrides):**
  - On stock-out trigger, **immediately** send the PO to the **last-known-cheapest** supplier for that item (already stored from previous bills). No waiting.
  - Run the "request quotes from all suppliers" as a **separate periodic price-refresh** that updates who "cheapest" is — NOT in the stock-out critical path.
  - If PO-approval toggle is ON, the admin can still review/redirect before it sends.
- **Confirm with owner:** this changes what "lowest cost supplier" means operationally (last-known-cheapest, refreshed periodically, vs live quote round). Flag before building.

---

## SECTION D — Technician app changes (CONFIRMED, build)

### D1. Technician sells AMC on-site — CONFIRMED
- Add AMC-sell flow to the technician app: technician explains plan, signs customer up on-site.
- Customer-side new-AMC: if recommended by a technician, customer enters the **technician's name as referral**.
- **Critical:** the referral/technician name MUST feed the technician's **incentive/credit** (same `owner_id`-style plumbing as the enquiry-finder credit — do not build it as a dead field that's never read).

### D2. Completion confirmation — OTP with fallback — DECISION (recommendation given)
- Default: **OTP** generated in the customer app per work order; customer reads it to the technician to confirm completion. (Replaces on-screen digital signature.)
- Fallback if customer won't/can't use the app — **RECOMMENDED three-tier, build this:**
  1. OTP (customer has app) — strongest, default.
  2. **On-screen signature on the technician's phone** (customer signs the tech's device, no app needed) — real fallback, still captures customer consent.
  3. **Photo proof** — last resort only, and flagged in the system as **"unverified completion"** so admin can see which jobs closed without customer confirmation.
- Reason: a technician-uploaded photo alone proves nothing about customer agreement (technician controls it) → fraud gap. The signature-on-tech-phone step keeps consent meaningful without an app.
- **Confirm with owner:** approve the three-tier fallback vs "OTP or any photo."

### D3. Location on Work-Started — CONFIRMED
- The saved address pin (entered by customer/ops) can be inaccurate.
- When the technician presses **Work Started**, if the pinned coordinates are wrong, the technician can **capture their current GPS as the site coordinates**; the productivity timer auto-starts at that moment.
- Store the technician-captured location as the **corrected** coordinate and update the customer's saved address for future visits. **Keep both** original + corrected (so a wrong capture can be undone). Do not silently overwrite.

### D4. SOP checklist after before-photo — CONFIRMED build, DECISION on data model
- After the before-photo is uploaded, show the **SOP checklist**.
- SOP standard time is per **inventory/spare item** (owner analogy: back wheel 10 min, horn 5 min; tank clean 5 min). Google review collection = +2 min credit; each extra complaint collected = +2 min credit. All add into the technician's total time.
- **DECISION:** does the checklist show a **pre-set fixed list**, or is it **populated from the spares/items the job involves**? Owner's per-item framing suggests the latter (list built from the inventory items on the job, each carrying its standard time). **Resolve this before building the data model** — building the wrong one is expensive to undo.
- Duration source: use the lightweight per-item default minutes (the SOP-time *master screen* stays out of scope unless owner raises it).

### D5. Job screen fields — CONFIRMED
- Technician sees one assigned complaint at a time. On open: address, name, flat/street/area, contact + additional contact (contact = **tap-to-call**), then product, model, **name of complaint**, **description** (voice/text notes from admin — already exists), appointment time, type (paid/warranty/AMC), **priority**, and **history button**.

### D6. History depth — VERIFY then fill gap
- Owner wants history to show **at least the last 2 services, or the full year**, including **parts changed** and the **previous technician's notes** ("pump weak, replace in 3 months").
- **Action:** check whether stored history includes previous-technician notes + parts-changed, not just dates. If only dates are stored, add notes + parts-changed — the notes are the point.

---

## SECTION E — Complaint types + diagnostics

### E1. Complaint-name master (product-specific, admin-editable) — SCOPE-GUARD (now authorized)
- Master list of complaint types, each **tagged to a product type**, admin-editable.
- Feeds a **filtered auto-suggest dropdown** on both the customer booking screen and the admin complaint screen: typing "N" shows only matching types for that product (AC → Not Cooling, Sound Problem, Leakage; RO → No Water, No Taste — different lists).
- Admin can add a missing complaint type to any product's list.
- "Name of complaint" = pick from this product-filtered list. "Description" = free voice/text notes on top (E in D5).
- This is the previously-declined "Complaint-name Master." Owner requested it directly and in detail → **authorized change request, build it.**

### E2. AI diagnostic steps — PARKED (later phase)
- Separate feature from E1. Owner has trained step-by-step troubleshooting (e.g. "no water in RO" → check SV inlet valve → SV unit → pump) he wants shown as a guided checklist keyed off the complaint.
- Needs its own data (his trained steps). **Park with the WhatsApp flow for a later phase.** Do not fold into this build.

---

## SECTION F — Reviews and reports

### F1. Google review flow — CONFIRMED (settings-driven)
- Star threshold is a **setting** (default 5-star shows the Google-review link; admin can lower to 4 if they want more reviews). Below threshold → internal feedback only ("why this rating?"), does not go to Google. Google-review button wires to whatever threshold is set.
- **Open item to resolve (do not lose):** owner's **double-review concern** — app review + Google review showing twice. Note as "to resolve," bring back for a decision.

### F2. Reports with filters — CONFIRMED
- With-GST / without-GST reports, combined; AMC / spare / product revenue split; monthly revenue; payments — all on one dashboard.
- **Filters on everything:** month, previous month, this year, all-time, category. Choosing a filter shows the matching data.
- **Prerequisite:** filters are only as good as input categorisation. **Enforce category tagging at input time** (every expense/sale tagged with a category) or filters return empty. Build the tagging, not just the filter UI.

---

## SECTION G — Assignment logic corrections (feeds the earlier logic-change spec)

These correct the technician-assignment spec based on what the owner confirmed.

### G1. Drop skill-matching as a blocking filter — CORRECTION
- Owner deliberately reduced product types to **RO / Inverter / Battery only**, so **ALL technicians handle ALL three** — no specialization split.
- In the assignment engine: **keep the `skills` column** (for future expansion, e.g. Bangalore) but **do NOT gate assignment on it.** The skill filter is a no-op for now.

### G2. Assignment logic = two rules — CONFIRMED
- Owner's stated logic: **(1) nearest technician, (2) customer appointment availability + technician availability must align.**
- First complaint assigned on attendance; second only after the first completes (one open appointment per technician). Confirmed.

---

## SECTION H — Parked for later (do NOT build this pass)

- **H1. WhatsApp product-enquiry flow** — owner gave the tree (Buy/Service/AMC/Spares → product → budget bands ₹8–10K/₹10–15K/₹15–20K → website link; AMC = Amazon-style 4 plans with video + voice + one-click buy + enquiry button). Park; revisit after this build. **(Reminder flagged per owner request.)**
- **H2. AI diagnostic steps** (E2).
- **H3. Salary / rewards / incentives** — owner will explain by call. Await input.
- **H4. Product data / billing format / catalog** — owner will send via Excel. Await input.

---

## Open decisions to lock before building the DECISION items

1. **C3 — PO supplier selection:** confirm "instant PO to last-known-cheapest + separate periodic price-refresh" (recommended) vs live quote round.
2. **D2 — OTP fallback:** confirm three-tier (OTP → sign-on-tech-phone → photo-marked-unverified) vs "OTP or any photo."
3. **D4 — SOP checklist data model:** pre-set list vs populated-from-job-items (recommended). Resolve before building the data model.
4. **A2 — working-hours end time:** confirm 7:00 / 7:30 / 6:30.
5. **F1 — double-review concern:** decide how to avoid app+Google double review.

## Change-request list to raise with owner (previously declined, now building)

- Complaint-name master (E1).
- Exemption / availability-exception windows (B4).

---

## Build order

Section A (settings-wiring, verify) → G (assignment corrections) → B (booking model) → C1/C2 (reorder + toggle) → D1/D3/D5/D6 (technician app) → E1 (complaint master) → F (reviews + reports). Lock the five open decisions before D2, D4, C3. Do not build Section H.

Each item shippable and verifiable on its own. For every settings-driven item, the verification step (change setting → behaviour changes) is mandatory before marking done.
