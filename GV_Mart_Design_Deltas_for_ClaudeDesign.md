# GV Mart — Design Deltas to hand to Claude Design (aligned to signed v2.2)

**Authority:** the client-signed **Requirement Confirmation v2.2 (28 June 2026, prepared by Sirah Digital for Mr. Ramesh)** is the source of truth. Everything below updates the designs (`GV_Mart_ClaudeDesign_Workflow_Complete.md`, given to Claude Design) so they match that signed document **exactly**. Where v2.2 differs from earlier internal drafts, **v2.2 wins.** Screen IDs refer to the design file.

> Keep the Finexy visual system. Only change content/values/behaviour to match v2.2. Do **not** add scope beyond the PDF — items the PDF leaves vague stay vague (the client didn't sign off on extra detail).

---

## A. VALUE CORRECTIONS — set these exactly as in v2.2

1. **Inventory reorder (§6.10):** minimum stock **10**, reorder quantity **10**. → ADM-18, ADM-20. *(Use 10, not 50.)*
2. **Travel time (§6.6):** **1 km = 5 minutes** (admin-set standard) for the distance-reach indicator. → ADM-15, technician map. *(Use 5 min/km.)*
3. **Customer review threshold (§6.7):** the Google review link shows to the customer **only when they rate 4.5 or 5**, not below. → CUST rating screen. *(Technician-side review in §6.5 is just "each Google review received" — no star gate on the technician side.)*
4. **Attendance ticks (§6.8):** after attendance the technician ticks **Affirmation and Pledge, then Meeting**. If they arrive **after 9:15 AM**, attendance + meeting + affirmation + pledge ticks are **locked** (admin can change the time). → TECH-01, ADM-16.
5. **Salary (§6.8):** describe as **revenue-based, master-configurable** — "above a certain revenue, incentive applies; higher daily revenue raises the monthly salary on a set scale." **Do NOT hardcode ₹ figures** (the signed doc gives none). → ADM-24 shows the scale as admin-set.
6. **Lunch break (§6.5):** **30 minutes allowed; over 45 minutes shows red.** → technician tracking / ADM-15.
7. **Geofence (§6.8):** attendance can be marked **only inside the office** (geo-fenced). **No specific distance figure in v2.2 — don't show "30 feet".** → TECH-01.

---

## B. RULES & FIELDS TO ADD / CONFIRM (present in v2.2)

### Sales & billing (§6.1)
8. Search customer by **name or number** → choose **Sales or Service**; under Sales choose **Spares or Product**. → ADM-05.
9. **Product sale order:** select **product → brand → model**, price shows, choose payment method, apply discount, offer gift, offer **AMC (RO only)**, set **warranty yes/no with auto reminder**, ask **installation yes/no**. If installation = yes → **service ticket auto-raised and auto-assigned**. → ADM-06.
10. **Two separate bills** when a customer buys product + spares together. → ADM-05.
11. **Gift** auto-offered above a set amount (water bottle / jute bag); everything recorded/measurable. → ADM-05.
12. **Payment:** Cash or Bank transfer; **bank transfer requires transaction/ID + a short description**. → ADM-05.
13. **Discount limits:** technician **up to 5%**, admin **up to 10%**, **above 10% not allowed at all**. → ADM-05, TECH-07, ADM-30.

### AMC (§6.2)
14. Plans **Gold / Silver / Platinum**, each for a chosen **number of years**; **price auto-calculated, more years = lower rate**; plans/prices/inclusions in the **AMC master**. → ADM-13.
15. **AMC service doesn't charge the customer, but spares used still reduce stock** — AMC **doesn't add to revenue but reduces inventory**. → ADM-07, TECH-07.
16. **If a used part isn't covered by AMC, its price is added to the bill, and the bill cannot be closed until it's added.** → ADM-07, TECH-07 (blocking rule).
17. **AMC auto-schedules a service every 3 months, with a description**; AMC sold **only on RO**. → ADM-12/13.

### Warranty (§6.3)
18. **Scheduled** (every 3 months from first service date) **and Unscheduled** (issues after a sale; e.g. new product ~10 days in, unpredictable issues). → ADM-10/ADM-12.
19. **Auto service-type** (AMC / Warranty / Paid) decided from **customer address, product, brand, model**; **staff cannot choose Paid by hand**; **purchase date shown; for AMC, AMC date + expiry shown**. → ADM-10.

### Service & complaints (§6.4)
20. Complaint records **product, brand, model, name of complaint** (customer's words, e.g. "AC not cooling") + **nature of complaint** (found after visit, e.g. "gas refill needed"). → ADM-10.
21. **Call priority:** very urgent / urgent / normal. Appointment: **Always available** or specific time/date with exceptions; **working time 9:00 AM–7:30 PM**. → ADM-10/ADM-11.
22. **Repeat/urgent callers** considered when assigning. **One person can't have two open appointments**; next allocated only after current completes. → ADM-11.
23. **Completed-job report fields:** appointment date & time, **service start time, service close time, total time taken**. → ADM-09 ticket detail.

### Technician app & field work (§6.5)
24. Open app → **search address** (shows customer **name + contact number**); **tapping the number starts the call, and calls are tracked and recorded**. → TECH-05.
25. Job screen shows **product, brand, model, complaint, appointment time** (by customer availability) + **previous history** + **Paid/Warranty/AMC**. → TECH-06.
26. **AMC scheduled service (e.g. changing the sponge) shows with no service charge**; **paid service shows quantity + cost from master**; **warranty/AMC cost = 0 but quantity still recorded**. → TECH-06/07.
27. **Before image on arrival, after image after work** (both mandatory). **Each process/part change has a fixed standard time; exceeding it shows red.** → TECH-07.
28. **Spares selected by search or voice (Tamil)** → create invoice → **technician + customer both sign**. → TECH-07.
29. **RO checklist:** Before TDS, After TDS, **Tank cleaned (yes/no), client name, product explained (yes/no)**. → TECH-07.
30. **New enquiry** (service/product/AMC) recorded with description (**voice in Tamil ok**), saved as a **lead in the technician's name**; technician **earns incentive** on it. → TECH-07.
31. **Lunch 30 min; >45 min red** (A6). **Technician earns incentive per Google review received, at an admin-set value.** → TECH.

### Location tracking & dispatch (§6.6)
32. After attendance, technician receives the **day's spare bag** (based on **previous day's cumulative invoices**); a **technician-wise spare availability list** is maintained; **admin + technician both sign** given/received. → TECH-02, ADM-17.
33. **First work decided after attendance, or technician chooses which job first**; every technician has assigned work. → TECH-03.
34. **1 km = 5 min** standard (A2); **green if reached within expected time (distance-reach indicator); red box if wrong route or staying 5–10 min, showing how long they stayed**. **Timer starts automatically on reaching the location.** → ADM-15, TECH-04.

### Customer app (§6.7)
35. Fill address → **Service Booking, Spare Enquiry, Product Enquiry, AMC Enquiry**. → CUST-01.
36. **Service Booking = guided chat**; existing product auto-shows, else select, else **auto-added to a service enquiry**. → CUST-02.
37. **Product Enquiry** → website or **auto-send videos + quotation, then close**. → CUST-04.
38. **AMC self-booking only when renewal date is near** (admin sets how many days before). → CUST-03.
39. **Customer review link shows only at 4.5 or 5** (A3). → CUST rating.
40. **Admin can edit the customer enquiry flows anytime** from the admin section. → ADM-23 (mark flows as admin-editable).

### Attendance, salary, incentives, rewards (§6.8)
41. Geo-fenced attendance (A7); Affirmation + Pledge + Meeting; 9:15 lock (A4). **Late → deduction based on late hours.** → TECH-01, ADM-16, ADM-24.
42. **Incentives** from **extra service income, sales income, reviews**, set in the **incentive master** (values admin-set — no fixed % unless client provides). → ADM-25.
43. **Rewards:** on-time attendance every day (monthly), highest review (monthly), highest revenue; **admin logs each reward given**; **reward thresholds are exact** (e.g. highest-revenue reward only at/above a set figure). → ADM-26.
44. **Reference points:** a customer reference earns points; **admin sets value per point (minimum 50)**; accumulated points reflect **as agreed** (keep vague — no "1 pt = ₹1", no "1000 points"). → ADM-22/CUST-09.

### Leads & WhatsApp (§6.9)
45. **Every enquiry** (field / customer app / WhatsApp) captured as a **lead with source + technician name** where relevant. → ADM-22.
46. **AI WhatsApp agent** sends the right video by enquiry type: **online-use, price, quality, customization, water-premium, budget** (admin sets the flow). → ADM-23.
47. **Lead → quotation → sale, ratio tracked.** → ADM-08/ADM-22.

### Inventory, purchase, suppliers (§6.10)
48. Min stock + reorder (A1: **10 / 10**); **low stock → auto WhatsApp PO to supplier**; **suppliers linked to products, order goes to lowest-cost supplier**; **bill entry defaults previous bill + supplier**. → ADM-18/19/20/21.

### Reports & performance (§6.11)
49. **Sales reports:** number of calls; **product/spare/AMC split as ratios**. **Service reports technician-wise with average value per call.** **Total revenue includes technician report.** **Performance scoreboard (KRA, KPI)** built from these. **Expenses:** marketing, stationery, salary, petrol. → ADM-27/28/29.

### Operations & sales admin (§6.12)
50. **Daily to-do list** (like the manual diary): completed items **close at end of day**, pending **move to next day**. → ADM-31.
51. **WhatsApp automation treated as compulsory**; **agent confirmation call before a technician starts an appointment (one check before)**; admin works through **notifications, follow-ups, reminders, dashboards, reports**. → ADM-31.
52. **Operation Admin measured on on-time complaints (within 24h) + same-day service; Sales Admin on call ratios; both earn incentive.** → ADM-29.

---

## C. OPEN ITEMS FROM v2.2 (don't finalise in the design)

53. **Consumable naming "spun / sponge" (§7 Q1):** keep it a **configurable master name** until Ramesh confirms; don't hardcode a label.
54. **WhatsApp business number (§7 Q2):** pending — no UI dependency; note automation depends on approval.

---

## D. DO NOT ADD (not in the signed v2.2 — keep out of the client-facing design)

To match what Ramesh signed, **do not introduce** these unless raised as a change request (they were in older internal drafts, not the PDF): SOP-Time Master screen, Complaint-name Master, Zone/Area Master, Vendor price-history, GST-filing checklist, Bank-payment-tracking screen, availability-exception windows, first-dispatch 10–50 ft trigger, 30-ft geofence figure, referral "1 pt = ₹1", fixed incentive rates (1–1.5%, ₹25/₹50), fixed salary bands (₹15k/₹20k). Keep the design at v2.2's level of detail.

---

## Build stages to mirror (v2.2 §8)

1. **Stage 1:** Core sales, billing, service logging, inventory.
2. **Stage 2:** Technician app — attendance, live location tracking, job photos, checklist, on-the-spot billing, call tracking.
3. **Stage 3:** AMC & Warranty automation + Customer app (admin-editable enquiry flows).
4. **Stage 4:** Salary, incentives, rewards.
5. **Stage 5:** WhatsApp automation, auto POs, full reports.

---

## Ready-to-paste prompt for Claude Design

> Update the GV Mart designs to match the **client-signed Requirement Confirmation v2.2**. Keep the Finexy visual system. Apply these exactly:
>
> **Values:** inventory **min 10 / reorder 10**; travel **1 km = 5 min** (green if on time, red box if wrong route or idle 5–10 min showing how long); customer Google-review link shows **only at 4.5 or 5 stars**; attendance ticks **Affirmation + Pledge + Meeting**, locked after **9:15 AM**; **lunch 30 min, red over 45 min**; geofence = "**inside office**" only (no distance figure); salary is **revenue-based and admin-set — show no fixed ₹ figures**.
>
> **Rules to reflect:** product sale flow (product→brand→model→price→payment→discount→gift→AMC RO-only→warranty y/n auto-reminder→installation y/n → auto ticket+assign); **two bills** for product+spares; **transfer needs transaction ID + description**; discount **≤5% technician, ≤10% admin, >10% blocked**; **AMC auto-schedules every 3 months, RO-only, cost 0 but stock still reduces, uncovered part must be added before the bill can close**; **service type auto-decided, Paid never chosen by hand, purchase date + AMC date/expiry shown**; complaint **name vs nature**; priority very-urgent/urgent/normal; working hours **9:00–7:30**; **one open appointment per person**; job report shows **start, close, total time**; technician job screen with **tap-to-call (calls tracked)**, before/after photos, **fixed SOP time (red if exceeded)**, spares by **search or Tamil voice**, **both signatures**, RO checklist **(Before TDS, After TDS, Tank cleaned, client name, product explained)**, field enquiry saved as a **lead in the technician's name** for incentive; spare-bag from **previous day's cumulative invoices** with **admin+technician sign**; customer app tiles **(Service/Spare/Product/AMC)**, guided-chat booking, **AMC self-book only near renewal**, **admin-editable enquiry flows**; leads captured from all sources with **source + technician**, **AI WhatsApp videos by enquiry type**, **lead→quote→sale ratio**; **auto WhatsApp PO to lowest-cost supplier on low stock, bill-entry defaults previous supplier**; reports (calls count, product/spare/AMC ratio, technician-wise avg per call, total revenue incl. technician report, KRA/KPI scoreboard, expenses marketing/stationery/salary/petrol); **daily to-do that carries forward**, **compulsory WhatsApp automation**, **agent confirm-call before dispatch**; Operation Admin KPI = 24h/same-day, Sales Admin KPI = call ratios.
>
> **Reference points** stay generic ("admin sets value per point, min 50, reflect as agreed"). **Keep "spun/sponge" as a configurable name.** **Do not add** SOP-time/complaint-name/zone masters, vendor price-history, GST checklist, bank-tracking, availability-exception windows, or any fixed salary/incentive/referral numbers — those aren't in the signed scope.

---

### One-line summary
Everything here comes from the **client-signed v2.2 PDF** and is set as the authority — including reverting reorder to **10** and travel to **5 min/km** — so the delivered design matches exactly what Ramesh approved, with nothing added beyond that scope.
