# Tamil strings pending review (Wasi WhatsApp templates, Wave 1)

English is the source; Tamil is a draft until a Tamil speaker signs it off. **Do not submit any `_ta` template to Wasi/Meta before its row is signed off** (a rejected or wrong approved template cannot be edited in place). Delete or tick an entry once reviewed.

Audience: customers in Chennai, polite and colloquial-but-respectful. Brand and product names (GV Mart, AMC, Google, Rs, product names) and numbers stay in Latin script. Variables in `{{double_braces}}` must be left exactly as written. Please also check that each sentence still reads naturally when the variable is filled with a typical value (a name, an 8-letter reference, a date, a product name).

Terminology used consistently (matches the app's existing Tamil, see `tamil-review-batch17.md`): technician = தொழில்நுட்பர்; service request = சேவை கோரிக்கை; invoice = இன்வாய்ஸ்; app = செயலி; AMC plan = AMC திட்டம்.

Specific questions for the reviewer are marked **Q**.

## Template bodies

| Key (template name) | English | Tamil (draft) | Notes |
|---|---|---|---|
| `gvm_service_booked_ta` | Hi {{customer_name}}, your service request {{ticket_ref}} for {{complaint}} has been booked with GV Mart. We will assign a technician shortly and keep you updated on this chat. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} ({{complaint}}) GV Mart-இல் பதிவு செய்யப்பட்டுள்ளது. விரைவில் தொழில்நுட்பரை நியமித்து, இந்த உரையாடலிலேயே தகவல் தெரிவிப்போம். | **Q:** `{{complaint}}` is staff-typed English or Tamil text in brackets; is the bracket form fine? |
| `gvm_technician_assigned_ta` | Hi {{customer_name}}, technician {{technician_name}} has been assigned to your service request {{ticket_ref}}. Scheduled time: {{slot}}. You can follow the visit in the GV Mart app. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}}-க்கு தொழில்நுட்பர் {{technician_name}} நியமிக்கப்பட்டுள்ளார். திட்டமிடப்பட்ட நேரம்: {{slot}}. வருகையை GV Mart செயலியில் பின்தொடரலாம். | `{{ticket_ref}}-க்கு`: suffix attached to a variable; confirm it reads correctly with a reference like A1B2C3D4. |
| `gvm_technician_on_the_way_ta` | Hi {{customer_name}}, technician {{technician_name}} has left for your service request {{ticket_ref}} and should reach you in about {{eta}}. Please keep the product easy to reach. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}}-க்காக தொழில்நுட்பர் {{technician_name}} புறப்பட்டுள்ளார். சுமார் {{eta}} நேரத்தில் வந்து சேருவார். பொருளை எளிதில் அணுக வசதி செய்யவும். | **Q:** `{{eta}}` will be a value like `30 min`; does "சுமார் 30 min நேரத்தில்" read well, or should the value be passed as a Tamil phrase? |
| `gvm_service_completed_ta` | Hi {{customer_name}}, your service request {{ticket_ref}} has been completed. You can view the service details in the GV Mart app. Thank you for choosing GV Mart. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} நிறைவடைந்தது. சேவை விவரங்களை GV Mart செயலியில் பார்க்கலாம். GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி. | |
| `gvm_feedback_request_ta` | Hi {{customer_name}}, we have completed your service request {{ticket_ref}}. Please tell us how the service went by opening the GV Mart app with the button below. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}} நிறைவடைந்தது. சேவை எப்படி இருந்தது என்பதை கீழே உள்ள பொத்தானைத் தொட்டு GV Mart செயலியில் தெரிவிக்கவும். | **Q:** is "பொத்தான்" the word customers use for a button, or is "பட்டன்" more natural? |
| `gvm_google_review_ta` | Hi {{customer_name}}, thank you for choosing GV Mart for {{service}}. If you have a minute, you are welcome to share your experience on Google using the button below. | வணக்கம் {{customer_name}}, {{service}}-க்காக GV Mart-ஐ தேர்ந்தெடுத்ததற்கு நன்றி. ஒரு நிமிடம் இருந்தால், கீழே உள்ள பொத்தான் மூலம் Google-இல் உங்கள் அனுபவத்தைப் பகிரலாம். | Must stay neutral: no pressure, no mention of stars, ratings, rewards or satisfaction. Please do not add any of those while polishing. **Q:** same "பொத்தான்" question. |
| `gvm_invoice_issued_ta` | Hi {{customer_name}}, your invoice {{invoice_no}} dated {{invoice_date}} for Rs {{amount}} has been issued. You can view it in the GV Mart app. Thank you for shopping with GV Mart. | வணக்கம் {{customer_name}}, {{invoice_date}} தேதியிட்ட உங்கள் இன்வாய்ஸ் {{invoice_no}} (ரூ {{amount}}) வழங்கப்பட்டுள்ளது. GV Mart செயலியில் பார்க்கலாம். GV Mart-இல் வாங்கியதற்கு நன்றி. | **Q:** "இன்வாய்ஸ்" (transliteration) vs "விலைப்பட்டியல்"; the app's Tamil for invoice should be matched. |
| `gvm_amc_welcome_ta` | Hi {{customer_name}}, welcome to the {{plan_name}} AMC plan for your {{product_name}}. Your plan is valid until {{expiry_date}}. We will contact you to schedule your service visits. | வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான {{plan_name}} AMC திட்டத்திற்கு வரவேற்கிறோம். திட்டம் {{expiry_date}} வரை செல்லுபடியாகும். சேவை வருகைகளை திட்டமிட நாங்கள் உங்களைத் தொடர்பு கொள்வோம். | AMC/warranty wording follows the existing app (உத்தரவாதம் for warranty). |
| `gvm_amc_visit_scheduled_ta` | Hi {{customer_name}}, your AMC service visit for {{product_name}} is scheduled on {{visit_date}}. Please keep the product easy to reach for the technician. | வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான AMC சேவை வருகை {{visit_date}} அன்று திட்டமிடப்பட்டுள்ளது. தொழில்நுட்பர் வரும்போது பொருளை எளிதில் அணுக வசதி செய்யவும். | |
| `gvm_amc_expiring_ta` | Hi {{customer_name}}, your AMC for {{product_name}} expires on {{expiry_date}}, which is {{days_left}} days from today. Reply to this message if you would like to renew or speak to our team. | வணக்கம் {{customer_name}}, உங்கள் {{product_name}}-க்கான AMC {{expiry_date}} அன்று முடிவடைகிறது; இன்னும் {{days_left}} நாட்கள் உள்ளன. புதுப்பிக்க அல்லது எங்கள் குழுவுடன் பேச இந்த செய்திக்கு பதிலளிக்கவும். | `{{days_left}}` is 30, 15 or 7. Not promotional: keep it factual. |

## Button labels (fixed URL buttons, maximum 25 characters each)

| Template(s) | English | Tamil (draft) | Notes |
|---|---|---|---|
| `gvm_technician_assigned_ta` | Open GV Mart app | GV Mart செயலியைத் திற | **Q:** "திற" (open) vs "திறக்க"; check the 25-character limit once entered. |
| `gvm_service_completed_ta` | View details | விவரங்களைப் பார் | |
| `gvm_feedback_request_ta` | Share feedback | கருத்தைப் பகிர் | |
| `gvm_google_review_ta` | Share on Google | Google-இல் பகிர் | Neutral; no "review" or "rate" wording. |
| `gvm_invoice_issued_ta` | View invoice | இன்வாய்ஸைப் பார் | |

## Footer (all templates)

| English | Tamil (draft) | Notes |
|---|---|---|
| GV Mart | GV Mart | Brand name stays in Latin script in both languages. |

## Example values for the Tamil submissions

Meta needs an example per variable. Examples can be in Latin script, which is what the system will actually pass for names, references and dates. Please confirm Tamil examples are not preferred for `{{complaint}}`, `{{service}}`, `{{product_name}}` and `{{plan_name}}` (the system fills these from English product and plan names today).
