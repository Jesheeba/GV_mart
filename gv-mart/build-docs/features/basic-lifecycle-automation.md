# Feature: Basic Lifecycle Automation (12 approved templates only)

Scope note: this is the **basic/fixed** automation layer. The advanced Segment Builder plan in `PLAN.md` is unchanged and untouched — this feature ships first, the advanced builder stays as a later, separate phase.

## Purpose
Wire each of the 12 originally-submitted `gvm_*` templates to the one real app event it belongs to, following the customer's actual journey: Lead → Quoted → Converted/Customer → Service → Payment → AMC → Feedback.

## The 12 templates — exact approved text, pulled live from Wasi just now

| # | Stage | Trigger (fires when) | Template | Approved body (verbatim) |
|---|---|---|---|---|
| 1 | New Lead | a lead/enquiry is created | `gvm_product_enquiry` | "Dear {{customer_name}}, thank you for your product enquiry with GV MART! Product: {{product_name}}. Enquiry No.: {{enquiry_number}}. Our sales team will contact you shortly." |
| 2 | Quoted | a quotation is generated for that lead | `gvm_quotation_generated` | "Dear {{customer_name}}, your detailed quotation for {{product_name}} is now fully ready for your review. Quotation No.: {{quotation_number}}. Total Amount: Rs {{amount}}." |
| 3 | Converted | an invoice/sale is created (lead becomes customer) | `gvm_purchase_confirmation` | "Dear {{customer_name}}, thank you for purchasing {{product_name}} from GV MART! Your purchase has been successfully registered." |
| 4 | Installed | installation marked complete | `gvm_installation_completed` | "Dear {{customer_name}}, your {{product_name}} has been successfully installed!" |
| 5 | AMC signed | new AMC contract registered | `gvm_amc_registration` | "Dear {{customer_name}}, your Annual Maintenance Contract has been successfully registered. AMC Number: {{amc_number}}. Valid Until: {{expiry_date}}." |
| 6 | AMC expiring | 30 / 15 / 7 days before AMC expiry | `gvm_amc_renewal_reminder` | "Dear {{customer_name}}, your AMC {{amc_number}} is expiring soon on {{expiry_date}}. Please renew to continue uninterrupted service." |
| 7 | Complaint booked | a service ticket is booked | `gvm_complaint_registration` | "Dear {{customer_name}}, thank you for registering your complaint. Complaint Number: {{complaint_number}}." |
| 8 | Technician assigned | a technician is assigned to the ticket | `gvm_technician_assigned` | "Dear {{customer_name}}, a technician has now been assigned. Technician Name: {{technician_name}}. Technician Contact Number: {{technician_phone}}." |
| 9 | On the way | technician marked en route | `gvm_technician_on_the_way` | "Dear {{customer_name}}, our technician {{technician_name}} is now on the way to attend Complaint No. {{complaint_number}}." |
| 10 | Completed | ticket marked completed | `gvm_service_completed` | "Dear {{customer_name}}, your service Complaint No. {{complaint_number}} has now been successfully completed." |
| 11 | Payment received | a payment is recorded | `gvm_payment_received` | "Dear {{customer_name}}, thank you for your payment! We have received Rs {{amount}} against Complaint No. {{complaint_number}}." |
| 12 | Feedback | shortly after service completion | `gvm_customer_feedback` | "Dear {{customer_name}}, thank you for choosing GV MART! Please share your feedback here: {{feedback_link}}." |

Rows 7–10 and 12 are today's **existing live triggers** (already fire today, sending free text — this feature just switches them to the approved templates above). Rows 1–6 and 11 are **new triggers**, built fresh — nothing fires for these events today.

## ⚠️ One mismatch to flag before building
You described the first lead message as **"Thank you for choosing GV Mart"** with an **"Explore more products" button**, after which the existing bot replies "what are you looking for."

None of the 12 approved templates has any button, and `gvm_product_enquiry` (the closest match) is worded as a confirmation of an enquiry already made — not a generic welcome. Meta also doesn't let us edit an approved template's text or add a button to it after the fact.

So for row 1, I see two options:
- **(A)** Use `gvm_product_enquiry` exactly as approved (text above, no button) as the new-lead message — ships immediately, no new approval needed.
- **(B)** Write and submit a new template with the "Explore more products" button wording you described, then wire that instead once Meta approves it (takes review time, and would make this a 13th template — outside today's "12 only" instruction).

**Please pick (A) or (B) for row 1 before I build.** Rows 2–12 have no such mismatch — their trigger and wording line up cleanly.

## Build plan (once row 1 is decided)
1. Apply the already-written Chunk A migration (rows 7,8,9,10,12 above) to the live DB — still blocked by the permission classifier; needs your action or a permission grant.
2. Build new DB triggers for rows 1, 2, 3, 6, 11 (lead created, quotation generated, invoice/sale created, AMC expiry cron reuse, payment recorded) — reusing the existing `whatsapp_outbox` + `sendMessage()` path, no new send engine.
3. Build new DB trigger + mapping for row 5 (AMC registered).
4. Add `whatsapp_event_templates` mapping rows for all 12.
5. Tests per trigger + regression run on the existing milestone dispatch tests.
6. Update `TESTING.md`/`CHANGELOG.md`, commit per the usual per-feature workflow.
