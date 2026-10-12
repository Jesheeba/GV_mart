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
| `gvm_technician_arrived_ta` | Hi {{customer_name}}, technician {{technician_name}} has arrived for your service request {{ticket_ref}} and has started the service. | வணக்கம் {{customer_name}}, உங்கள் சேவை கோரிக்கை {{ticket_ref}}-க்காக தொழில்நுட்பர் {{technician_name}} வந்து சேவையைத் தொடங்கியுள்ளார். | **Q:** "வந்து சேவையைத் தொடங்கியுள்ளார்" (has arrived and started the service): natural for a technician, or should it read "வந்துள்ளார்" only? |
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

## WhatsApp bot replies for STOP / STOP ALL / START (not templates; automation Phase 3 / Stage A)

These are free-text replies sent inside the 24-hour window, right after the customer writes STOP, STOP ALL or START (code: `supabase/functions/_shared/wa-opt-out.ts`). They are not submitted to Wasi. DRAFT: needs review by a Tamil speaker.

| Key | English | Tamil (draft) | Notes |
|---|---|---|---|
| `wa.opt_out.stop` | You will no longer receive feedback requests, renewal reminders or promotional messages from GV Mart. Updates about your service requests and invoices will continue. Reply STOP ALL to stop every message, or START to subscribe again. | GV Mart-இலிருந்து கருத்து கோரிக்கைகள், புதுப்பிப்பு நினைவூட்டல்கள் மற்றும் விளம்பர செய்திகள் இனி வராது. உங்கள் சேவை கோரிக்கைகள் மற்றும் இன்வாய்ஸ் தகவல்கள் தொடர்ந்து வரும். அனைத்து செய்திகளையும் நிறுத்த STOP ALL என்றும், மீண்டும் பெற START என்றும் பதிலளிக்கவும். | The keywords STOP ALL and START stay in Latin script. |
| `wa.opt_out.stop_all` | You will not receive any more messages from GV Mart. Reply START to subscribe again. | GV Mart-இலிருந்து இனி எந்த செய்தியும் வராது. மீண்டும் பெற START என்று பதிலளிக்கவும். | |
| `wa.opt_out.start` | You are subscribed again. Thank you. | நீங்கள் மீண்டும் சேர்க்கப்பட்டுள்ளீர்கள். நன்றி. | |
| keywords (recognised, whole message only) | STOP, UNSUBSCRIBE, STOP ALL, STOPALL, START, SUBSCRIBE, RESUME | நிறுத்து, நிறுத்துங்கள், அனைத்தையும் நிறுத்து, எல்லாவற்றையும் நிறுத்து, தொடங்கு, தொடங்குங்கள் | **Q:** any other Tamil words customers actually type to stop or restart? |

## App strings added with the preferred-language field (Stage A, S2)

| Key | English | Tamil (draft) |
|---|---|---|
| `customers.form.preferredLanguage` / `customerApp.profile.preferredLanguage` | Message language (optional) | செய்தி மொழி (விருப்பம்) |
| `*.preferredLanguageHint` | WhatsApp messages are sent in this language. Leave empty for English. | WhatsApp செய்திகள் இந்த மொழியில் அனுப்பப்படும். காலியாக விட்டால் ஆங்கிலம். |
| `*.languageEnglish` / `*.languageTamil` / `*.languageNotSet` | English / Tamil (தமிழ்) / Not set (English) | ஆங்கிலம் / தமிழ் / அமைக்கப்படவில்லை (ஆங்கிலம்) |
