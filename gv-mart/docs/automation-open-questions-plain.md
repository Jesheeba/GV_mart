# Automation: the 16 open questions in plain words (2026-10-12)

For: the shop owner. No technical knowledge needed.
Numbering is the same as section 14 of `docs/plan-automation-flows.md`, so answers can be traced back.

How to answer: copy the message at the bottom, change only the lines you want to change, and send it back. Replying "defaults" means you accept every recommended answer.

## Decisions already made (not asked again)

1. Every possible business event (a customer joining an AMC, an AMC ending, a spare enquiry, a product enquiry and so on) can be turned into an automatic message trigger, and every trigger leaves an audit entry.
2. The master builds the flows. Videos and messages can be chosen for each stage. Nothing is fixed in code.
3. End-to-end testing uses only the one permanent test customer "jeshee test trigger" (the test number ending 6740, Sirah Digital address in Pallavaram). Real WhatsApp messages during tests go only to that number. A test-send allow-list setting (OFF by default) blocks and logs messages to any other number.
4. Google reviews: the technician has an input box while finishing the service; the customer gets a WhatsApp message after the service and also a QR code on the technician's phone (both). No customer reward is tied to reviews.
5. The installation cost is bound to the technician incentive; the master can edit the amount.

## A. Where things stand today

### 1. Is the system messaging real customers right now?
- **Question:** At the moment, are real customers getting WhatsApp messages from the system, or is it effectively switched off?
- **Why it matters:** It decides how carefully we must switch each message over, so nobody gets the same message twice or none at all.
- **Recommended default:** Assume yes, treat it as live, and move one message type at a time while the old and new ways run side by side.
- **If different:** If it is truly off, we can switch everything on in one go and skip the side-by-side step.

## B. When and how messages go out

### 2. What counts as "technician is on the way"?
- **Question:** The app has no moment when the technician says "I am leaving now". Should we add a "Start travel" button for the technician, or guess it from the phone's location?
- **Why it matters:** Without a real departure moment, the "on the way" message would really say "arrived", which is wrong.
- **Recommended default:** Add a "Start travel" button (one extra tap, always accurate). Until it exists, the "on the way" message stays off.
- **If different:** Using the phone's location needs no tap but is sometimes late or wrong.

### 3. How strictly must we avoid repeats?
- **Question:** A customer should not get the same message twice. Should that mean "not twice for the same job, with a waiting period between similar messages", or "only once in their whole life" for some messages such as the welcome and the review request? And how many days apart may two review requests be?
- **Why it matters:** "Once ever" would block good repeats (a second repair, a second AMC); too loose would feel like spam.
- **Recommended default:** Never twice for the same job, plus a waiting period between similar messages. Review requests at least 90 days apart.
- **If different:** If you choose "once ever" for welcome or review, those customers will never get a second one, even years later.

### 4. What does "STOP" stop?
- **Question:** If a customer replies STOP, should that stop every WhatsApp message, or only promotions and reminders, while job updates and invoices keep coming?
- **Why it matters:** Promotions and review or renewal requests need a way to stop; job updates are things the customer usually needs.
- **Recommended default:** STOP stops promotions, review requests and renewal reminders. Messages about a job they booked and their invoices continue. "STOP ALL" stops everything.
- **If different:** If STOP must stop everything, customers could miss a technician-arrival or invoice message.

### 5. Who gets the Google review request?
- **Question:** Do we ask every customer after a completed service, or only customers who seem happy?
- **Why it matters:** Google does not allow asking only the happy customers (check Google's current policy page before launch). Offering gifts for reviews is also not allowed.
- **Recommended default:** Ask every customer after every completed service, with no condition on how it went. If a customer gives a low rating, the master and operations are alerted in addition, not instead.
- **If different:** Asking only happy customers risks the reviews being removed or the listing being penalised.

### 6. Which events message the customer?
- **Question:** For which events should the customer get a WhatsApp message by default, and which are for staff only? For example, telling a customer their lead is "contacted" or "quoted" is unusual.
- **Why it matters:** Too many messages annoy people; too few leave them guessing.
- **Recommended default:** Customers get: booked, assigned, on the way, completed, invoice, AMC welcome, AMC visit and AMC expiring, feedback and review. A lead moving to "won" gets a thank-you; "lost" never messages the customer.
- **If different:** Each of these is a switch the master can turn on or off later; nothing is locked.

### 7. Do staff want WhatsApp too?
- **Question:** Should technicians, sales people and the master also get WhatsApp messages (new job, new lead, alerts), or stay with in-app notifications only?
- **Why it matters:** Each staff message needs its own approved template and a working number for every person.
- **Recommended default:** In-app only for the first release; turn on WhatsApp for "new job" (technician) and "new lead" (sales) in the second wave.
- **If different:** If you want staff WhatsApp from day one, three more templates (six submissions) must be added to the first wave.

## C. Quotes, invoices and customers

### 8. Send quotations and invoices from the system instead of the phone?
- **Question:** Today staff tap a button that opens their own WhatsApp with a ready text. Should the system send it directly instead, so there is a record and an approved template?
- **Why it matters:** Messages sent from a staff phone are not recorded and are not controlled by the automation.
- **Recommended default:** Yes, send from the system. Keep the old button as a manual backup until staff are comfortable.
- **If different:** If staff must edit the words each time, those messages stay manual and outside the automation record.

### 9. How do we know a customer's language?
- **Question:** Customers without an app login have no language saved. Should we add a "preferred language" to each customer, set when they are first entered, or let the sales person choose at that moment?
- **Why it matters:** The system picks the Tamil or English message from this.
- **Recommended default:** Add a preferred-language field to every customer, chosen at entry, English if empty.
- **If different:** If we only follow the sales person's choice at that moment, a customer's language can change from message to message.

### 14. Family members: whose mobile gets the message?
- **Question:** Should messages go only to the main customer's mobile, or also to family members' mobiles that are saved?
- **Why it matters:** Sending to several people multiplies messages and may reach someone who never asked.
- **Recommended default:** Main customer's mobile only.
- **If different:** Adding members means each member also needs to be able to opt out.

## D. Testing

### 10. Which staff accounts do tests use?
- **Question:** The test technician login that exists today: is it a real person's account? Can we create one extra test technician and one test sales person, marked as "test", so tests never land on a real person?
- **Why it matters:** If tests use real staff, their jobs, notifications and performance figures get polluted.
- **Recommended default:** Create a dedicated test technician and a dedicated test sales person, both marked as test, and do not reuse any real person's account.
- **If different:** If you prefer to reuse an existing test account, we must confirm it is not a real person first.

### 11. Test sales and stock
- **Question:** To test invoice messages we need a test sale. May it be a service-only sale (no product leaves stock), knowing that it uses up one invoice number?
- **Why it matters:** A sale with a product would change stock and finance figures.
- **Recommended default:** Yes, service-only line, and the used invoice number is accepted.
- **If different:** If skipped invoice numbers are a problem, invoice messages cannot be tested end to end.

## E. Limits and timing

### 12. Quiet hours and daily limit
- **Question:** Confirm "no messages between 9 pm and 8 am" (held until morning) and "at most 3 WhatsApp messages per customer per day".
- **Why it matters:** Protects customers from late-night or too many messages, and protects the WhatsApp number's reputation.
- **Recommended default:** 9 pm to 8 am quiet, 3 per customer per day.
- **If different:** A higher limit risks complaints and WhatsApp blocking the number; a lower one can hold back important job messages.

### 13. How fast must "send after some minutes" be?
- **Question:** Messages go out when a scheduled check runs. Is a delay of several minutes acceptable, or must it be tighter, which means moving the check inside the database?
- **Why it matters:** The current scheduler can run late (earlier checks found it firing hours apart), which makes "technician is on the way" useless if it arrives late.
- **Recommended default:** Accept a few minutes of delay for the first release; move to the database scheduler before the "on the way" message goes live.
- **If different:** If you accept long delays everywhere, no extra work, but "on the way" must stay off.

## F. Suppliers and unassigned leads

### 15. Supplier messages (RFQ and purchase orders)
- **Question:** Keep the supplier quote and purchase-order messages exactly as they are for the first release, or bring them into the new system now?
- **Why it matters:** They already work through their own path; moving them adds risk without helping customers.
- **Recommended default:** Keep as they are in the first release; share only the audit and the kill switch.
- **If different:** Bringing them in now delays the customer messages by roughly a few working days.

### 16. Who is the "sales person" when a lead has no owner?
- **Question:** When a new lead has no sales person yet (the automatic rotation is switched OFF), who should get the message meant for the sales person?
- **Why it matters:** Otherwise nobody is told about the lead.
- **Recommended default:** The master.
- **If different:** If you pick "all sales staff", each of them receives it and may all call the same customer.

## Reply template

Copy everything below, change only what you want, and send it back.

```
Automation answers (defaults pre-filled)

1  Real customers messaged today: yes, treat as live, switch one message type at a time
2  On the way: add a "Start travel" button for the technician; keep the message off until it exists
3  Repeats: never twice for the same job + waiting period; review requests at least 90 days apart
4  STOP: stops promotions, review requests and renewal reminders; job updates and invoices continue; STOP ALL stops everything
5  Google review: ask every customer after every completed service, no condition; low ratings also alert master and operations
6  Customer messages by default: booked, assigned, on the way, completed, invoice, AMC welcome/visit/expiring, feedback, review; lead "won" thank-you only
7  Staff WhatsApp: in-app only now; add technician "new job" and sales "new lead" WhatsApp in the second wave
8  Quotations and invoices: send from the system; keep the old button as a backup for now
9  Language: add a preferred-language field per customer, English if empty
10 Test accounts: create a dedicated test technician and a test sales person, both marked test
11 Test sale: service-only line, used invoice number accepted
12 Quiet hours 9 pm to 8 am; 3 messages per customer per day
13 Timing: accept a few minutes of delay now; move to the database scheduler before "on the way" goes live
14 Family members: main customer's mobile only
15 Supplier messages: keep as they are in the first release
16 Lead with no owner: send to the master
```
