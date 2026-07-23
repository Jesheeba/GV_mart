# GV Mart — Verify Phase 2, Then Phase 3 (Agent Instructions + Owner Checklist)

This file has two parts:
- **Part 1 — for the AGENT:** finish proving Phase 2 works, then proceed.
- **Part 2 — for ME (the human):** the few things only I can do or check.

---

## PART 1 — FOR THE AGENT

Phase 2 is deployed and confirmed not to crash, but it is **NOT yet proven to actually work** — the test environment had only one technician, and he was already busy, so the new zone/skill/capacity filter never got exercised. "Deployed without errors" is not "verified." Do the following before Phase 3.

### 1. Permission granted: modify the seed/test data
You paused before mutating seed state — that was correct. You now have approval to change TEST data. Either add a **second test technician**, or free up the existing technician's in-progress job, so there are genuinely two candidates to choose between. Prefer adding a second technician so the original seed state is preserved.

### 2. Run the real positive-path verification (this is the actual Gate 2)
With two technicians available, create/re-run the two test tickets (one RO, one AC) and confirm the NEW filter behaviour visibly:
- Zone filter works: an out-of-zone technician is not chosen.
- Capacity filter works: a technician at their daily ceiling is skipped.
- Spare-in-bag filter works: a technician missing the needed part is skipped.
- One job actually gets assigned to an eligible technician (a clean positive path, not just "unassigned").

### 3. Confirm the G1 rule explicitly — skill must NOT block
Per the owner's decision, product specialization was removed — ALL technicians handle RO / Inverter / Battery. Answer clearly in your report:
> Does the new skill filter EXCLUDE a technician who lacks the skill, or is it a no-op that keeps the `skills` column but never blocks anyone?

It must be a no-op (kept for future use, never excludes). If it currently blocks, fix it so skill does not gate assignment. Re-verify after the fix.

### 4. Clean up test tickets
Cancel/remove the `Phase2 verify RO` and `Phase2 verify AC` tickets (and any created in step 2) cleanly, so no stray test data is left in the ticket list.

### 5. Report back, then STOP for review
Report: the positive path proven (with what you saw), the G1 skill answer, and confirmation the test tickets are cleaned up. Do NOT start Phase 3 until the human reviews this.

### 6. Only after human approval — Phase 3
Phase 3 = distance-first ranking + fairness tiebreak + finder/loyalty preference (per the assignment spec). Do not stack it on an unverified Phase 2.

---

## PART 2 — FOR ME (THE HUMAN)

Things the agent CANNOT do — only I can. Short list.

### A. Watch the re-test with my own eyes
When the agent re-runs the two test tickets (RO + AC) with two technicians, I look at the screen and confirm it behaves sensibly:
- [ ] A job actually gets assigned to a technician (not stuck "unassigned").
- [ ] It doesn't pick someone in the wrong area, someone already full, or someone without the part.
- [ ] Both an RO job and an AC job can go to the SAME technician (proving skill is NOT blocking — this is the G1 rule).
I don't need to read code — just confirm the assignment looks right.

### B. Get answers to the 5 decision questions (some are Ramesh's call)
Nothing on these can be built until answered:
- [ ] OTP / how a customer confirms a finished job if they won't use the app.
- [ ] SOP task-time checklist — how it's built.
- [ ] Purchase-order supplier — how the system picks who to order from.
- [ ] Working hours end time — 7:00 / 7:30 / 6:30?
- [ ] Double-review — how to avoid app + Google review twice.

### C. Chase what Ramesh owes me
- [ ] Salary / rewards / incentives details (he said he'd explain by call).
- [ ] Product data, prices, billing format (he said he'd send via Excel).

### D. Approve Phase 3 only after A is done
- [ ] I've seen the filter work with my own eyes, skill confirmed non-blocking, test tickets cleaned up → then tell the agent to start Phase 3.

---

**One line:** the agent adds a second technician, proves the filter really works (and that skill doesn't block), cleans up, and stops. I watch that it looks right, get Ramesh's answers on the 5 decisions, and only then greenlight Phase 3.
