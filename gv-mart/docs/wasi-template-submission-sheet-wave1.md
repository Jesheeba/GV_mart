# Wasi template submission sheet, Wave 1 (2026-10-12)

Status: DOCUMENT ONLY. Nothing was submitted, sent, built or written to a database. All Tamil text is **DRAFT: needs review by a Tamil speaker** (strings are also listed in `docs/tamil-review-wasi-templates.md`).

Source documents: `docs/plan-automation-flows.md` (the automation design; section 9 lists the 32 template names), `docs/plan-dispatcher-fix.md` (separate plan, branch `docs/dispatcher-fix-plan`; referenced only, not duplicated), the Wasi API facts of 12 Oct 2026 given in the brief, and the current send code (`supabase/functions/_shared/whatsapp.ts`, `wa-milestone-dispatch-core.ts`, `wa-scheduled-tasks`, milestone triggers in migration `20260819170000`).

The owner's test number is referred to only as "the test number ending 6740".

## 0. Read first: where this sheet differs from the design document

The design document predates the Wasi API reference. This sheet follows the Wasi facts; every deviation is deliberate:

| # | Design document says | This sheet does | Why |
|---|---|---|---|
| 1 | One name, submitted twice (`en` and `ta`) | Two names: `<base>_en` and `<base>_ta` | Wasi picks arbitrarily between two languages of one name, and there is no language field on send. The dispatcher plan already uses the suffix convention. |
| 2 | Numbered variables `{{1}}..{{n}}` | Named variables (`{{customer_name}}`) | Wasi passes named variables as an object; order does not matter, so the "variable order caveat" in design 9.3 (items 3 and 11) disappears. |
| 3 | Variables carrying links (`summary_link`, `rating_link`, `link`, `review_url`) | Fixed URL buttons only | Dynamic button parameters are not supported. Links that would have been variables are now fixed button URLs (customer app, Google review page). |
| 4 | Google review template is Marketing, shown only to high ratings is an option | Submitted as Utility, sent to every completed service, no rating condition | Brief rules (Meta wording, Google policy: no gating, no rewards). Fallback if Meta re-categorises it: section 3.6 and section 2 (`consent_required`). |
| 5 | Wave 1 = 10 names, but the table marks 11 as Wave 1 | Wave 1 = 10 names. `gvm_amc_visit_reminder` moves to Wave 2 | The dispatcher plan already maps AMC visit reminders to the approved `appointment_reminder` template, so Wave 1 does not need a new one. |
| 6 | Variable names `name`, `technician`, `summary_link`... | `customer_name`, `technician_name`, ... | Matches the already-approved templates (`appointment_reminder`, `invoice_document` use `customer_name`). The dispatcher plan's mapping table should be updated to these keys (it lists `name`). |

## 1. Conventions used in every template below

- **Language codes.** English submissions use `en`; Tamil submissions use `ta`. Reason: `en` is the generic English code and matches the design document and dispatcher plan; the account's approved `shipping_update` / `appointment_reminder` are `en_US`, and `po_quote_request_doc_v3` exists in both `en_US` and `en`, which is the live example of the ambiguity bug. Because every name here carries its own `_en` / `_ta` suffix and is unique, the English code chosen cannot cause an ambiguity. If the Wasi dashboard only offers "English (US)", pick `en_US`; nothing else changes.
- **Category.** All 10 names are submitted as **Utility**. Per-template risk notes say where Meta might re-categorise.
- **Variables** are lowercase snake_case, named, never at the very start or very end of the body, never adjacent. Meta requires an example value for each one (listed per template).
- **Variable value hygiene** (applies to every send): no newlines, no tabs, no run of more than four spaces, trimmed, and a maximum of about 60 characters. Free-text sources such as `name_of_complaint` must be cleaned before sending.
- **Footer** (optional, all templates): `GV Mart`.
- **Buttons.** Static only. Two fixed URLs are needed, both are business settings the owner must confirm, neither is invented here:
  - `<CUSTOMER_APP_URL>`: the public address of the GV Mart customer app.
  - `<GOOGLE_REVIEW_URL>`: equal to `settings.google_review_url`. The URL inside an approved template is frozen, so if the setting ever changes, a new template version (`..._v2_en`) must be submitted.
- **Headers.** None of the 10 Wave 1 templates has a media header. The invoice PDF path stays with the already-approved `invoice_document` (needs a public PDF URL, which does not exist yet; see the dispatcher plan).
- **Ticket and invoice references** are the short ids the app already shows: first 8 characters of the id, upper case (for example `A1B2C3D4`). There is no separate human ticket number in the schema.
- **Customer name** comes from `customers.name`; the customer's language comes from `profiles.language` when the customer has a login, else the rule's default language (design 9.1).

## 2. Failure behaviour common to all templates

These rows apply to every template unless a template section says otherwise. Behaviour follows the dispatcher plan (sections b, c, e) and the design's gate order.

| Situation | What the system does | Retry |
|---|---|---|
| Template not approved yet, or missing from the template mirror | Nothing leaves. Outbox row `skipped_no_template`, error `no_approved_template:<event>_<lang>`, audit `skipped_no_approved_template`. Shown in Failed Sends with the reason. Free text is allowed only if the customer is inside the 24 h window and the rule opts in. | Never automatic. A human resends after approval. |
| `session_window_closed` (409) | Should be impossible for a template send. If seen, a free-text payload went out by mistake: row `failed`, error `session_window_closed`, master alert, treated as a bug. | None |
| `consent_required` (409) | Meta treated the template as Marketing and the customer has no opt-in. Row `failed`; template category in the mirror is flipped to marketing so the engine stops sending it to non-opted-in customers; master notified once per template. | None |
| `media_resolution_failed` (409) | Not expected: no Wave 1 template has a media header. If it appears, `headerMediaUrl` was sent for a template without a header: row `failed`, bug alert. | None |
| `plan_limit_reached` (409) | Row `failed`; the dispatcher stops the rest of that run (so the 3-attempt cap is not burned on every queued row); master alert. | Manual resend after the plan limit is resolved |
| `waba_not_connected` (409) | Row `failed`; global alert; dispatcher stops the run. | Manual resend after reconnecting |
| `conflict` (409) | Retried once on the same row. | Once |
| 502 `whatsapp_rejected` | Row `failed`; whole Meta error object and `fbtrace_id` kept. | None automatic |
| `message.status` = `failed` webhook | `delivery_status='failed'`, `failed_at`, cleaned error; appears in Failed Sends. | None (a template that cannot be delivered is not fixed by repeating it) |

Every 409 means nothing was sent or charged.

## 3. Templates

Each section gives the shared facts once (variables, header, buttons, events, rejection risks) and then the two language submissions with their own name, language code, category and body. Total: 10 sections, 20 submissions.

### 3.1 `gvm_service_booked` (event: `ticket.created`)

**Recipient:** customer. **When:** immediately when a service ticket is created through any channel (milestone `booked`; today `_milestone_ticket_notify` on `service_tickets` INSERT).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `ticket_ref` | first 8 chars of `service_tickets.id`, upper case | A1B2C3D4 |
| `complaint` | `service_tickets.name_of_complaint`, cleaned | RO water purifier not working |

**Header:** none. **Buttons:** none. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_service_booked_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, your service request {{ticket_ref}} for {{complaint}} has been booked with GV Mart. We will assign a technician shortly and keep you updated on this chat.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_service_booked_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} ({{complaint}}) GV Mart-இல் பதிவு செய்யப்பட்டுள்ளது. விரைவில் தொழில்நுட்பரை நியமித்து, இந்த உரையாடலிலேயே தகவல் தெரிவிப்போம்.`

**Failure behaviour:** section 2. Inside the 24 h window with no approved template, a free-text fallback is allowed (the booking usually comes from the app, so the window is normally closed).
**Rejection risks:** `{{complaint}}` is free text a staff member typed; a long or odd value could be flagged, so it is cleaned and truncated. Wording is purely transactional (no offer, no "best", no emoji).

### 3.2 `gvm_technician_assigned` (event: `ticket.assigned`)

**Recipient:** customer. **When:** when the ticket status becomes `assigned` (milestone `assigned`).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `ticket_ref` | as above | A1B2C3D4 |
| `technician_name` | assigned technician's profile display name | Murugan |
| `slot` | appointment `scheduled_at`, formatted in IST | 14 Oct 2026, 10:00 AM |

**Header:** none. **Buttons:** one fixed URL button, label `Open GV Mart app` (Tamil `GV Mart செயலியைத் திற`), URL `<CUSTOMER_APP_URL>`. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_technician_assigned_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, technician {{technician_name}} has been assigned to your service request {{ticket_ref}}. Scheduled time: {{slot}}. You can follow the visit in the GV Mart app.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_technician_assigned_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}}-க்கு தொழில்நுட்பர் {{technician_name}} நியமிக்கப்பட்டுள்ளார். திட்டமிடப்பட்ட நேரம்: {{slot}}. வருகையை GV Mart செயலியில் பின்தொடரலாம்.`

**Failure behaviour:** section 2. Interim until approved: the approved `appointment_reminder` (see 4.2), only if the owner accepts its "reply to confirm" wording.
**Rejection risks:** none specific. The customer app button must be a real, stable URL; a URL that redirects through a shortener can be rejected.

### 3.3 `gvm_technician_on_the_way` (event: `technician.on_the_way`)

**Recipient:** customer. **When:** when the technician leaves for the visit. **There is no departure signal in the app today** (design gap 1; the existing `milestone.on_the_way` fires when the visit starts, i.e. on arrival). The template can be submitted and approved now, but the flow cannot go live until a "Start travel" action or an agreed GPS rule exists (open question 2).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `technician_name` | assigned technician's profile display name | Murugan |
| `ticket_ref` | as above | A1B2C3D4 |
| `eta` | computed travel estimate (new; not in the schema today) | 30 minutes |

**Header:** none. **Buttons:** none. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_technician_on_the_way_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, technician {{technician_name}} has left for your service request {{ticket_ref}} and should reach you in about {{eta}}. Please keep the product easy to reach.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_technician_on_the_way_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}}-க்காக தொழில்நுட்பர் {{technician_name}} புறப்பட்டுள்ளார். சுமார் {{eta}} நேரத்தில் வந்து சேருவார். பொருளை எளிதில் அணுக வசதி செய்யவும்.`

**Failure behaviour:** section 2, plus one proposed rule: if the row is older than the master-configured limit (suggested 60 minutes) when the dispatcher picks it up, skip it as stale rather than tell a customer a technician "has left" an hour late. In the Tamil body the `eta` value must be a number-and-unit that reads naturally after "சுமார்" (for example `30 min`).
**Rejection risks:** low. Time-sensitive transactional wording is the textbook Utility case.

### 3.4 `gvm_service_completed` (event: `ticket.completed`)

**Recipient:** customer (technician and operations are in-app only in Wave 1). **When:** when the ticket status becomes `completed` (milestone `completed`).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `ticket_ref` | as above | A1B2C3D4 |

**Header:** none. **Buttons:** one fixed URL button, label `View details` (Tamil `விவரங்களைப் பார்`), URL `<CUSTOMER_APP_URL>`. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_service_completed_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, your service request {{ticket_ref}} has been completed. You can view the service details in the GV Mart app. Thank you for choosing GV Mart.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_service_completed_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} நிறைவடைந்தது. சேவை விவரங்களை GV Mart செயலியில் பார்க்கலாம். GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி.`

(The design had a `summary_link` variable. It is replaced by the fixed app button because link variables cannot be turned into buttons.)

**Failure behaviour:** section 2. **Rejection risks:** the closing thank-you must stay a sentence of thanks, not an invitation to buy again.

### 3.5 `gvm_feedback_request` (event: `feedback.requested`)

**Recipient:** customer. **When:** the existing scheduled rule, N hours after completion (today `runFeedbackRequests` in `wa-scheduled-tasks`, plain text, 25 h dedupe). Sent to **every** completed service.

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `ticket_ref` | as above | A1B2C3D4 |

**Header:** none. **Buttons:** one fixed URL button, label `Share feedback` (Tamil `கருத்தைப் பகிர`), URL `<CUSTOMER_APP_URL>`. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_feedback_request_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, we have completed your service request {{ticket_ref}}. Please tell us how the service went by opening the GV Mart app with the button below.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_feedback_request_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} நிறைவடைந்தது. சேவை எப்படி இருந்தது என்பதை கீழே உள்ள பொத்தானைத் தொட்டு GV Mart செயலியில் தெரிவிக்கவும்.`

**Failure behaviour:** section 2. No free-text fallback outside the window (the old plain-text message is retired by this template). The old "one tap" rating in the message is not possible without a dynamic button; the rating happens in the app after the button tap.
**Rejection risks:** medium. Meta sometimes treats satisfaction surveys as Marketing. The body avoids "help us improve", stars and anything promotional. If it is re-categorised, the `consent_required` path in section 2 applies and the owner must decide whether to keep it (open question 4/5).
**Policy:** this message and the Google review message go to every completed service, regardless of any rating, so this one cannot be used to decide who receives the other.

### 3.6 `gvm_google_review` (event: `review.google_requested`)

**Recipient:** customer. **When:** after a completed service, with a master-configured delay (suggested a few hours to one day after completion), once per customer per cooldown (design default 90 days). **Sent to every customer with a completed service. There is no rating or satisfaction condition and no reward.** The design's "only 4.5 and above" idea (design section 12, risk 10) must not be used.

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `service` | short label of the service done (ticket type plus product, from the ticket) | RO water purifier service |

**Header:** none. **Buttons:** one fixed URL button, label `Share on Google` (Tamil `Google-இல் பகிர`), URL `<GOOGLE_REVIEW_URL>` (value of `settings.google_review_url`; the real URL is not recorded in this sheet). **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_google_review_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, thank you for choosing GV Mart for {{service}}. If you have a minute, you are welcome to share your experience on Google using the button below.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_google_review_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, {{service}}-க்காக GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி. ஒரு நிமிடம் இருந்தால், கீழே உள்ள பொத்தான் மூலம் Google-இல் உங்கள் அனுபவத்தைப் பகிரலாம்.`

**Wording rules (do not change without re-checking):** no reward, gift, discount, points or "free"; no mention of stars, ratings, "5-star", "positive" or "satisfied"; no condition ("if you were happy"). The design's wording "we would be grateful" is dropped because it reads as persuasion.

**Failure behaviour:** section 2, no free-text fallback in any case. If Meta re-categorises it to Marketing, `consent_required` appears for customers without opt-in: the message is then sent only to opted-in customers and the QR path below carries the rest.
**Rejection risks:** high relative to the others. Meta may treat any review request as Marketing. Mitigations: neutral thank-you first, no urging, no incentive, and a button instead of a pasted link. Verify Google's current review policy page before go-live (no rewards, no gating); this session did not re-verify it.

**QR-code alternative (not WhatsApp).** On the technician's phone, at the end of the service, the technician shows a QR code that opens `<GOOGLE_REVIEW_URL>` so the customer can scan it on the spot. It is shown to every customer regardless of how the visit went, carries no offer, and has no dependency on the WhatsApp template. Whatever the technician types into the completion screen's review input box (owner decision) must not change whether the customer receives the WhatsApp message or the QR. A technician incentive per verified review is allowed (it is paid by the business to staff and does not depend on stars); it must never be mentioned to the customer.

### 3.7 `gvm_invoice_issued` (events: `invoice.issued`, `sale.completed`)

**Recipient:** customer. **When:** when an invoice is created (today `_milestone_invoice_notify`; one sale can create several invoices, so dedupe is per invoice).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `invoice_no` | first 8 chars of `invoices.id`, upper case | 9F8E7D6C |
| `invoice_date` | invoice creation date, IST, `DD Mon YYYY` | 12 Oct 2026 |
| `amount` | invoice total, formatted with thousands separator | 1,250.00 |

**Header:** none (the PDF path remains the approved `invoice_document`, see 4.2). **Buttons:** one fixed URL button, label `View invoice` (Tamil `இன்வாய்ஸைப் பார்`), URL `<CUSTOMER_APP_URL>`. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_invoice_issued_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, your invoice {{invoice_no}} dated {{invoice_date}} for Rs {{amount}} has been issued. You can view it in the GV Mart app. Thank you for shopping with GV Mart.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_invoice_issued_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, {{invoice_date}} தேதியிட்ட உங்கள் இன்வாய்ஸ் {{invoice_no}} (ரூ {{amount}}) வழங்கப்பட்டுள்ளது. GV Mart செயலியில் பார்க்கலாம். GV Mart-இல் வாங்கியதற்கு நன்றி.`

(The design had a `link` variable and the dispatcher plan lists `link` for this template; both are replaced by the fixed app button.)

**Failure behaviour:** section 2. **Rejection risks:** a transaction receipt is core Utility; the risk is only the closing sentence, which must not become "shop again".

### 3.8 `gvm_amc_welcome` (event: `amc.joined`)

**Recipient:** customer. **When:** when an AMC plan is sold (`sell_amc_plan`, `sell_amc_plan_onsite`, `create_sale`).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `plan_name` | AMC plan name (`amc_plans`) | Gold |
| `product_name` | `products.name` of the covered product | Aquaguard RO |
| `expiry_date` | AMC contract `expiry_date`, `DD Mon YYYY` | 11 Oct 2027 |

**Header:** none. **Buttons:** none. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_amc_welcome_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, welcome to the {{plan_name}} AMC plan for your {{product_name}}. Your plan is valid until {{expiry_date}}. We will contact you to schedule your service visits.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_amc_welcome_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான {{plan_name}} AMC திட்டத்திற்கு வரவேற்கிறோம். திட்டம் {{expiry_date}} வரை செல்லுபடியாகும். சேவை வருகைகளை திட்டமிட நாங்கள் உங்களைத் தொடர்பு கொள்வோம்.`

**Failure behaviour:** section 2. **Rejection risks:** a "welcome" can drift toward Marketing; the body states plan, product and validity only. No upsell, no benefits list.

### 3.9 `gvm_amc_visit_scheduled` (event: `amc.visit_scheduled`)

**Recipient:** customer (technician is in-app). **When:** when a visit ticket is created for a contract. Note: the visit-scheduling emitter is New in the design (no WhatsApp sender today).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `product_name` | `products.name` | Aquaguard RO |
| `visit_date` | scheduled date of the AMC visit ticket, IST | 15 Jan 2027 |

**Header:** none. **Buttons:** none. **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_amc_visit_scheduled_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, your AMC service visit for {{product_name}} is scheduled on {{visit_date}}. Please keep the product easy to reach for the technician.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_amc_visit_scheduled_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான AMC சேவை வருகை {{visit_date}} அன்று திட்டமிடப்பட்டுள்ளது. தொழில்நுட்பர் வரும்போது பொருளை எளிதில் அணுக வசதி செய்யவும்.`

(The design's closing "we will remind you before the visit" is dropped: that reminder is a Wave 2 flow and the sheet must not promise a message that does not exist yet.)

**Failure behaviour:** section 2. **Rejection risks:** low.

### 3.10 `gvm_amc_expiring` (event: `amc.expiring`)

**Recipient:** customer (sales person is in-app). **When:** 30, 15 and 7 days before `expiry_date` (today `AMC_REMINDER_WINDOWS` in `wa-scheduled-tasks`, plain text; windows become master-configurable rule settings).

| Variable | Source | Example value |
|---|---|---|
| `customer_name` | `customers.name` | Priya Raman |
| `product_name` | `products.name` | Aquaguard RO |
| `expiry_date` | AMC contract `expiry_date`, `DD Mon YYYY` | 11 Oct 2027 |
| `days_left` | computed from the window (30, 15, 7) | 15 |

**Header:** none. **Buttons:** none (a reply opens the 24 h window and reaches the bot/staff). **Footer:** GV Mart.

**Submission 1 of 2**
- Name: `gvm_amc_expiring_en`. Language: `en`. Category: Utility.
- Body: `Hi {{customer_name}}, your AMC for {{product_name}} expires on {{expiry_date}}, which is {{days_left}} days from today. Reply to this message if you would like to renew or speak to our team.`

**Submission 2 of 2** (DRAFT: needs review by a Tamil speaker)
- Name: `gvm_amc_expiring_ta`. Language: `ta`. Category: Utility.
- Body: `வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான AMC {{expiry_date}} அன்று முடிவடைகிறது; இன்னும் {{days_left}} நாட்கள் உள்ளன. புதுப்பிக்க அல்லது எங்கள் குழுவுடன் பேச இந்த செய்திக்கு பதிலளிக்கவும்.`

**Failure behaviour:** section 2. Idempotency key includes the window (30, 15, 7) so a daily scanner never repeats a window. **Rejection risks:** medium; a renewal prompt can be read as Marketing. Wording states the fact first and offers a reply, with no price, discount or urgency. If re-categorised, `consent_required` applies and renewal reminders need customer opt-in.

## 4. Tables

### 4.1 Summary of all 20 submissions

| # | Name | Lang | Category | Variables | Header | Buttons | Event |
|---|---|---|---|---|---|---|---|
| 1 | `gvm_service_booked_en` | en | Utility | customer_name, ticket_ref, complaint | none | none | ticket.created |
| 2 | `gvm_service_booked_ta` | ta | Utility | same | none | none | ticket.created |
| 3 | `gvm_technician_assigned_en` | en | Utility | customer_name, ticket_ref, technician_name, slot | none | URL: app | ticket.assigned |
| 4 | `gvm_technician_assigned_ta` | ta | Utility | same | none | URL: app | ticket.assigned |
| 5 | `gvm_technician_on_the_way_en` | en | Utility | customer_name, technician_name, ticket_ref, eta | none | none | technician.on_the_way |
| 6 | `gvm_technician_on_the_way_ta` | ta | Utility | same | none | none | technician.on_the_way |
| 7 | `gvm_service_completed_en` | en | Utility | customer_name, ticket_ref | none | URL: app | ticket.completed |
| 8 | `gvm_service_completed_ta` | ta | Utility | same | none | URL: app | ticket.completed |
| 9 | `gvm_feedback_request_en` | en | Utility | customer_name, ticket_ref | none | URL: app | feedback.requested |
| 10 | `gvm_feedback_request_ta` | ta | Utility | same | none | URL: app | feedback.requested |
| 11 | `gvm_google_review_en` | en | Utility | customer_name, service | none | URL: Google review | review.google_requested |
| 12 | `gvm_google_review_ta` | ta | Utility | same | none | URL: Google review | review.google_requested |
| 13 | `gvm_invoice_issued_en` | en | Utility | customer_name, invoice_no, invoice_date, amount | none | URL: app | invoice.issued, sale.completed |
| 14 | `gvm_invoice_issued_ta` | ta | Utility | same | none | URL: app | invoice.issued, sale.completed |
| 15 | `gvm_amc_welcome_en` | en | Utility | customer_name, plan_name, product_name, expiry_date | none | none | amc.joined |
| 16 | `gvm_amc_welcome_ta` | ta | Utility | same | none | none | amc.joined |
| 17 | `gvm_amc_visit_scheduled_en` | en | Utility | customer_name, product_name, visit_date | none | none | amc.visit_scheduled |
| 18 | `gvm_amc_visit_scheduled_ta` | ta | Utility | same | none | none | amc.visit_scheduled |
| 19 | `gvm_amc_expiring_en` | en | Utility | customer_name, product_name, expiry_date, days_left | none | none | amc.expiring |
| 20 | `gvm_amc_expiring_ta` | ta | Utility | same | none | none | amc.expiring |

### 4.2 Existing milestone events mapped to templates

| Existing milestone (today's source) | Approved template that exists | Fit | Wave 1 template | Until the Wave 1 template is approved |
|---|---|---|---|---|
| Booked (`milestone.booked`, `_milestone_ticket_notify`) | none | n/a | `gvm_service_booked_*` | No send outside the 24 h window (`skipped_no_template`); free text only inside it |
| Assigned (`milestone.assigned`) | `appointment_reminder` (`customer_name`, `appointment_time`) | Imperfect: it is worded as an appointment reminder that asks the customer to reply to confirm; it has no technician name or ticket reference, and nothing handles the "reply to confirm" | `gvm_technician_assigned_*` | Owner decides: use `appointment_reminder` as a stop-gap (customer sees "reply to confirm"), or send nothing |
| On the way (`milestone.on_the_way`, fired by `service_visits` INSERT) | `shipping_update` (`name`) | **Wrong**: it says an order is out for delivery. The trigger fires at arrival, not departure | `gvm_technician_on_the_way_*` (needs a departure signal) | Do not use `shipping_update`. Pause this milestone until the departure signal exists; "arrived" is a Wave 2 template |
| Completed (`milestone.completed`) | none | n/a | `gvm_service_completed_*` | No send outside the window |
| Invoice issued (`milestone.invoice`, `_milestone_invoice_notify`) | `invoice_document` (`customer_name`, `invoice_number`, `invoice_date`, PDF header) | Good fit, but **blocked**: needs a public invoice PDF URL and no invoice PDF generator exists in the repo | `gvm_invoice_issued_*` (text, with app button) | Use the text template once approved; switch to `invoice_document` when a public PDF URL exists |
| AMC expiring (`wa-scheduled-tasks`, plain text) | none | n/a | `gvm_amc_expiring_*` | No send outside the window |
| AMC visit reminder (no sender today) | `appointment_reminder` | Acceptable | none in Wave 1 (Wave 2 if wanted) | Use the existing template |
| Feedback request (`wa-scheduled-tasks`, plain text) | none | n/a | `gvm_feedback_request_*` | No send outside the window |

`hello_world` stays for connectivity tests only. `po_quote_request_doc_v3` stays as is (its duplicate on Wasi's side is out of scope here).

## 5. Owner guide: create and submit a template in the Wasi dashboard

Templates cannot be submitted by API in this account (dashboard only). The field labels below follow the brief ("Templates > Create Template"); the Wasi screen may use slightly different wording, so check it against this list rather than trusting the labels.

1. Open the Wasi dashboard, go to **Templates**, then **Create Template**.
2. **Name:** paste the exact name from section 4.1 (for example `gvm_service_booked_en`). Lowercase, underscores only. Do not reuse a name for the second language.
3. **Language:** `en` for `_en` names, `ta` for `_ta` names (`en_US` if only that is offered, for English).
4. **Category:** Utility.
5. **Header:** none.
6. **Body:** paste the body exactly, including the `{{named}}` variables. Do not add a variable at the start or end. Do not add emoji.
7. **Examples:** for every variable enter the example value from the template's table. Do not leave any blank.
8. **Footer** (if the screen has one): `GV Mart`.
9. **Buttons:** none, or one **URL** button with the label from the template section and the fixed URL (`<CUSTOMER_APP_URL>` or `<GOOGLE_REVIEW_URL>`). Do not use any button that takes a variable.
10. Submit. Tamil (`_ta`) templates are submitted only after the Tamil review is signed off.
11. **Review time:** Authentication templates are usually reviewed in a few minutes. Utility reviews can take longer (minutes to a day or more); plan for the longer case.
12. **Checking status:** the dashboard shows the status, or call `GET /api/v1/templates`. Status is `approved`, `pending`, `rejected` or `paused`; a rejected template carries a `rejection_reason`. If rejected, change only the wording the reason points at, and submit under a new name (`..._v2_en`) if Wasi will not let the old name be reused.

If Meta re-categorises a template to Marketing at approval, do not accept it silently: record it and tell the developer, because the template then needs customer opt-in (`consent_required`).

## 6. Order of submission

Goal: the first end-to-end test (booking to the test number ending 6740) as early as possible.

| Batch | Templates | Why this order |
|---|---|---|
| 1 | `gvm_service_booked_en`, `gvm_service_completed_en` | No variables beyond name and reference, no button except one fixed URL; unlock the first real test: book a ticket as the test customer, complete it |
| 2 | `gvm_technician_assigned_en`, `gvm_invoice_issued_en` | Completes the visible service journey; need `<CUSTOMER_APP_URL>` confirmed |
| 3 | `gvm_amc_welcome_en`, `gvm_amc_visit_scheduled_en`, `gvm_amc_expiring_en` | AMC set; no button, no URL dependency |
| 4 | `gvm_feedback_request_en`, `gvm_google_review_en` | Highest rejection risk; needs `<GOOGLE_REVIEW_URL>` confirmed. Submit early enough that a rejection can be reworded while batches 1 to 3 are being tested |
| 5 | `gvm_technician_on_the_way_en` | Can be approved now, but cannot be used until the departure signal exists |
| 6 | All `_ta` templates, same order | After the Tamil review; the Tamil test uses a customer whose language is Tamil (open question 9) |

## 7. After approval checklist

1. Record the exact approved names and, from `GET /api/v1/templates`, the exact variable keys in `body_param_examples`. The keys must equal the names in this sheet; if Wasi stored different keys, the engine's per-send parameter validation will fail the row.
2. Note any template Meta re-categorised, and any rejected with its `rejection_reason`.
3. Update the event-to-template mapping (section 4.2 and the dispatcher plan table (f), which still lists `name` and `link`).
4. Sync the template mirror (`whatsapp_templates`: `wasi_name`, `language`, `param_keys`, `wasi_status`).
5. Run one test send per approved template to the test number ending 6740 only (never any other number), with the allow-list on. Check wording and the button on the handset.
6. Only then switch the matching rule from test-only to live.

## 8. Contradiction check (final step of the brief)

Re-read against the Wasi facts: no dynamic button (links are fixed URLs or removed); no template name shared across languages (every name carries `_en` or `_ta`); no Marketing submissions (all Utility, with the re-categorisation fallback written down); no review reward, rating, star or satisfaction wording; no variable at the start or end of any body; every variable has an example. The one open assumption that matters is whether Meta accepts `gvm_feedback_request` and `gvm_google_review` as Utility.
