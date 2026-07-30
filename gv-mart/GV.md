# GV Mart — Owner-Approved Decisions & Build Spec

**For:** Claude Code
**Source:** Owner (Ramesh) + Sirah Digital decisions, locked this round.
**Status:** APPROVED — build. Conflicts/risks flagged inline, but build instruction is given.

**Global rule:** every "set in settings" item must be wired so the admin settings value is the LIVE value the engine reads. Verify by changing the setting and confirming behaviour changes.

---

## 1. SOP checklist & task timing — APPROVED

### 1.1 Admin-set times per item
- Admin AND operation admin can set the standard time for **each product / inventory item**, and edit it anytime.
- These times drive the SOP checklist and the productivity timer.

### 1.2 Estimated time shown to technician
- On each job, the technician sees the **estimated time** for that service, from the admin-set item times.
- Admin also sets a **review time** and a **new-enquiry time** allowance (in settings). If review time = 5 min, then **estimated time + 5 min** is shown as the technician's total allowed time (same logic for the enquiry allowance).

### 1.3 Over-time behaviour
- If the technician doesn't complete within the allowed time, the job view turns **red**.
- When red, **all location/track details for that job show to the admin as a pop-up**.

### 1.4 Technician notes / voice note on the product (history)
- During service, the technician can add a **note or voice note** to the product (e.g. "pump weak, replace in 3 months").
- Stored as **product history** — a new technician handling the same product later can see the product's past history/notes.
- (Text acceptable for now; voice note is the target — build the field to support both.)

---

## 2. OTP job completion — APPROVED, keep + build the flow
- Keep OTP as completion confirmation: OTP generated in the customer app per work order; customer gives it to the technician to confirm completion.
- Build the full flow (generate → customer sees code → technician enters it → job confirmed complete).

---

## 3. Purchase Order — quotation-first, with safeguard — APPROVED (flagged)

### 3.1 Owner's instruction (build this)
- On reorder, first send a **quotation request** to the suppliers of that product/spare.
- Based on replies (price), the **PO is shown/sent to the lowest quoted supplier.**

### 3.2 SAFEGUARD — build in (prevents stock-out while waiting)
- **CONFLICT FLAG:** this "quote first, then order" reverses the earlier "order immediately to last-known-cheapest, quote separately" decision. Quote-first risks stock-out while waiting for replies. Build:
  - A **quotation timeout** (admin-set, e.g. 24 hrs). If not all reply by timeout, proceed with the lowest quote received so far.
  - If **no** supplier replies by timeout, **fall back to last-known-cheapest** and send the PO anyway, so stock is never stranded.
- Confirm the timeout value with the owner.

### 3.3 PO approval toggle (settings) — APPROVED
- Settings toggle: OFF = auto-send; ON = wait for admin approval before sending.

---

## 4. Route / movement colour tracking — APPROVED (new)

### 4.1 Colour rules
- **Green:** right direction, reached on time.
- **Yellow:** slow / reached late.
- **Red:** stayed idle somewhere — that place and route segment **marked**, route shows red.

### 4.2 Where it shows — two places
- **Per-job tab:** in the technician section, clicking the **customer's name** opens a separate tab showing that journey's route in colour (green/yellow/red, idle spot marked).
- **All-technician map:** on the existing all-technician-location screen, add a **"Track today's movement"** button → admin picks a technician → that technician's **full day's log shows in colour**.

---

## 5. Settings-page items — APPROVED (wire into existing settings)
Live value the system uses:
- **5.1 Reorder qty:** per spare — admin sets max & min; order qty = max − current.
- **5.2 Working-hours end time:** admin-set single value (booking + technician day). Owner to pick the number; editable.
- **5.3 PO approval toggle:** OFF auto-send / ON require approval (see 3.3).
- **5.4 SOP item times / review time / enquiry time:** per item + review & enquiry allowances (see 1.1, 1.2).
- **5.5 Google review threshold:** admin-set star level & limits (see 6).

---

## 6. Google review — APPROVED
- Customer gives **5 stars** → redirect to Google review page.
- **Threshold and limits admin-controlled in settings.**
- (Still open, don't lose: avoid the **double-review** — app + Google showing twice.)

---

## Flags for the human (decide / confirm)
1. **PO quote-first vs order-first (3.2):** switched to quote-first; safeguard (timeout + fallback) built in. Confirm timeout value with Ramesh.
2. **Working-hours end time (5.2):** needs Ramesh to pick the number.
3. **Double-review (6):** needs a final approach so the customer isn't reviewed twice.

## Build note
- 1.4 (voice-note-as-history) and Section 4 (colour route tracking) are the two larger new builds — each its own step with its own check. Everything else is wiring into existing screens/settings.