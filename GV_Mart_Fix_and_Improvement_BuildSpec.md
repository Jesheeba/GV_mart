# GV Mart — Fix & Improvement Build Spec
### From customer-side end-to-end testing · build all together, test, stop for review

**Context:** Customer-app testing pass complete. Most flows work (login, Service Booking guided wizard, draft restore, Spare/Product/AMC enquiries, AMC self-book → admin, leads capture). These are the issues and improvements found. Build the 🐞 bugs first, then the ✨ improvements. Keep everything within signed v2.2 scope — do NOT add anything on the DO-NOT-ADD list. Wire everything fully in **EN + த** with loading/empty/error states. Run the Definition of Done and stop for review.

---

## 🐞 BUGS — build these first

### BUG #1 — Time picker allows submit with no date/time
**Screen:** Customer App → Book a Service → Step 3 (Address / "When would you like the visit?")

**Problem:** When the user selects **"Pick a date & time"** but leaves the field empty (`dd-mm-yyyy --:--`), **Next** still lets them proceed. A booking can be submitted with no time even though they explicitly chose the specific-time option.

**Fix:**
- When **"Pick a date & time"** is selected, disable/block **Next** until a valid date+time is chosen.
- Show a validation message (e.g. "Please pick a date and time") if they try to continue without one.
- **"Anytime"** must still submit freely with no time — that's a valid §6.4 option.
- Also validate the chosen time falls within working hours (**9:00–19:30**, per §6.4).

---

### BUG #2 — Completed bookings still show as "Upcoming"
**Screen:** Customer App → Bookings

**Problem:** Bookings that are already **completed/ended** still appear under **"Upcoming"**; the Ended/Past tab is empty.

**Fix:**
- Filter the Bookings list on the appointment/ticket **status**.
- `scheduled` / `in_progress` → **Upcoming**
- `completed` (and cancelled, if applicable) → **Ended / Past**
- Past bookings should show their invoice + rating, as they do today.

---

### BUG #3 — No notification when a customer self-books an AMC
**Screen:** Admin (owner / operation_admin) → notifications (bell)

**Problem:** A customer self-booked an AMC from the customer app. The contract correctly appeared in **Admin → AMC & Warranty** ✅, but **no notification** was raised to the owner/ops.

**Fix:**
- Raise a notification to the relevant admin roles when a customer self-books/renews an AMC.
- **Also check whether notifications are firing at all** — a related gap was seen earlier (technician assignment only appears on refresh, no alert). Confirm the notifications pipeline works generally, not just for this event.

---

## 🔍 VERIFY / TRACE — confirm before changing anything

### VERIFY #1 — Do Service Bookings create a dispatchable service ticket?
When a customer books service for a product they **own** (a repair request), confirm it creates a **service ticket** that can be assigned to a technician — not *only* a sales lead.

Per §6.9, **all** enquiries (service/spare/product/AMC) becoming leads **is correct and per-spec** ("nothing slips through"). The question is narrower: a repair request must ALSO produce a dispatchable ticket. If service bookings only become leads with no ticket, technicians can't be sent — that's a real gap. **Trace and report; don't change without confirming.**

### VERIFY #2 — Did the AMC auto-schedule the FULL year of visits?
§6.2 requires an AMC to auto-schedule a service **every 3 months** across the contract year. A test AMC (Lakshmi Priya · Aquaguard · Silver) shows "Next SVC 11/1/2027" — confirm the **full year** of AMC-type service tickets was created (multiple visits ~3 months apart), not just one.

### VERIFY #3 — Product Enquiry videos
On Customer App → Product Enquiry, tapping a topic tag (Online / Price / Quality / Customization / Water Premium / Budget):
- Do actual **videos** appear, or is it empty?
- Is there an **admin screen** to upload/link a video per topic (the §6.9 video asset library)?
- Report whether this is "works, just needs content uploaded" vs "admin management screen missing."

---

## ✨ IMPROVEMENTS — build after the bugs

### IMPROVEMENT #1 — Service Booking product picker: My Products → categories → not sure
**Screen:** Customer App → Book a Service → Step 1 ("Which product needs service?")

**Problem:** Currently one long flat list of every product (batteries, ACs, purifiers all mixed) — hard to scan.

**Build three clear paths (Finexy style):**
1. **"My Products"** — shown **first**, default. Products the customer actually owns (from their purchase / invoice / warranty / AMC history). Tap one → straight to the Issue step. *This is the primary path per §6.7 ("the existing product shows automatically").*
2. **"Choose another product"** — opens a **category view** (AC · Battery · RO Purifier · Inverter, etc.) built from the product **catalog / masters** (NOT inventory stock levels). Tap a category → list its products → select one.
3. **"I'm not sure"** — **keep** the §6.7 fallback that auto-creates a service enquiry when the customer doesn't know their product. Do not remove this.

---

### IMPROVEMENT #2 — Clickable step navigation in the booking wizard
**Screen:** Customer App → Book a Service (Product → Issue → Address → Confirm)

**Build:**
- Make the **step indicators clickable** — tapping a completed step jumps directly to it.
- **All entered inputs must persist** when navigating between steps — nothing resets or clears.
- **Completed steps keep their green/checkmark state**; navigating back to edit must not change their visual status.
- Assume later steps **keep** their values when an earlier step is edited (only invalidate if the change makes them genuinely invalid).

---

### IMPROVEMENT #3 — Filter leads by enquiry type
**Screen:** Admin → Leads

**Build:** a filter so the team can view leads by **enquiry type — Service / Spare / Product / AMC** (and ideally by **source** — field / customer_app / WhatsApp / referral / walk-in). With all four enquiry types landing in Leads, this is needed to work the pipeline efficiently.

---

### IMPROVEMENT #4 — See all scheduled visits from an AMC contract
**Screen:** Admin → AMC & Warranty → click a contract

**Build:** clicking into an AMC contract should let the admin **navigate to the full schedule of service visits** for that contract — all upcoming (and past) 3-monthly visits, not just the single "Next SVC" date currently shown.

---

## ⏳ Needs from Ramesh (client-supplied — not build items)
- **WhatsApp business number** (§7)
- **Consumable name** — "spun" or "sponge" (§7)
- **Google review link** (from GV Mart's Google Business Profile) — the technician rating screen currently says "Google review link isn't configured yet"
- **6 topic videos** for Product Enquiry (Online, Price, Quality, Customization, Water Premium, Budget) — *recommend 6 general reusable videos, NOT per-product videos, which won't scale*
- **SOP-time decision** — admin-preset SOP steps/times vs the current technician-entered approach (an admin SOP-Time Master is on the DO-NOT-ADD list, so this needs his sign-off as a change request)
- **Existing-customer pipeline question** — should enquiries from *existing* customers still pass through the full New→Contacted→Quoted→Won lead pipeline, or be fast-tracked? (Current behavior follows §6.9 "every enquiry becomes a lead.")

---

## 🚫 Scope guard — do NOT build
SOP-Time Master screen · Zone/Area Master · Complaint-name Master · technician-set unavailability windows · availability-exception windows · vendor price-history · GST-filing checklist · bank-payment-tracking screen · fixed salary/incentive/referral numbers.

---

## Definition of Done
- `tsc -b`, `oxlint`, `npm run build` all clean
- All new strings wired in **EN + த** (no raw keys)
- Live-verified against the real backend (not mocked)
- Loading / empty / error states handled
- **Stop for review** before moving on
