# Tamil strings pending review (batch 17)

English is approved; Tamil is a draft until a Tamil speaker signs it off. Delete an entry once reviewed.

| Key | English | Tamil (draft) | Package |
|---|---|---|---|
| `service.quickFilters.pending` | Pending | நிலுவையில் | v (Service filters) |
| `nav.myDay`, `leads.myDay.title` | Daily Follow Up | தினசரி பின்தொடர்தல் | i |
| `leads.detail.backToMyDay` | Back to Daily Follow Up | தினசரி பின்தொடர்தலுக்குத் திரும்பு | i |
| `leads.myDay.badgeTitle` | Daily Follow Up: {{overdue}} overdue, {{today}} due today | தினசரி பின்தொடர்தல்: {{overdue}} தாமதம், இன்று {{today}} | i |
| `leads.source.field`, `service.channel.field` | Technician | தொழில்நுட்பர் (same word the app already uses for technician; old Tamil "கள" was truncated) | i |
| `service.newComplaint.stepEquipment` | Product | பொருள் | i |
| `service.newComplaint.discardWarning` | …(customer, product, details, appointment)… | …(வாடிக்கையாளர், பொருள், விவரங்கள், நியமனம்)… | i |
| `service.newComplaint.natureOfComplaint` | Complaint description (optional) | புகார் விவரம் (விருப்பம்) | i |
| `masters.tabs.leadKinds` / `masters.overview.leadKindsDesc` | Lead Kinds / {{count}} kinds | லீட் வகைகள் / {{count}} வகைகள் | ii |
| `masters.tabs.leadProductTypes` / `masters.overview.leadProductTypesDesc` | Lead Product Types / {{count}} product types | லீட் பொருள் வகைகள் / {{count}} பொருள் வகைகள் | ii |
| `masters.leadKinds.*` | Kind name, Tamil name (optional), Built-in, Custom, Add kind, hint and error texts (see ta.json) | வகையின் பெயர், தமிழ் பெயர் (விருப்பம்), உள்ளமைந்தது, தனிப்பயன், வகையைச் சேர் … | ii |
| `masters.leadProductTypes.*` | Product type name, Add product type, hint and error texts (see ta.json) | பொருள் வகையின் பெயர், பொருள் வகையைச் சேர் … | ii |
| seed: kind "Warranty" (`lead_kinds.label_ta`) | Warranty | உத்தரவாதம் (matches the existing AMC/warranty wording) | ii |
| seed: product type "Multigrade" (`lead_product_types.label_ta`) | Multigrade | மல்டிகிரேட் (transliteration) | ii |
| `customers.form.memberEmail`, `customerApp.profile.memberEmail` | Email (optional) | மின்னஞ்சல் (விருப்பம்) | iii |
| `customers.errors.emailInvalid`, `customerApp.errors.emailInvalid` | Enter a valid email address | சரியான மின்னஞ்சல் முகவரியை உள்ளிடவும் | iii |
| `customerApp.profile.memberProfession` | Profession (optional) | தொழில் (விருப்பம்) | iii |
| `leads.outcomeSheet.step2` | What was discussed (optional) | என்ன பேசப்பட்டது (விருப்பம்) | iv/17 |
| `leads.outcomeSheet.notePlaceholder` | What did you and the customer talk about? Anything to remember… | வாடிக்கையாளருடன் என்ன பேசினீர்கள்? நினைவில் வைக்க வேண்டியவை… | iv/17 |
| `leads.outcomeSheet.followupNeeded` | Follow-up needed? | பின்தொடர்தல் தேவையா? | iv/17 |
| `leads.outcomeSheet.yes` / `.no` | Yes / No | ஆம் / இல்லை | iv/17 |
| `leads.outcomeSheet.noFollowupHint` | The lead stays open and moves to the No follow-up tab until you schedule one. | லீட் திறந்தே இருக்கும்; நீங்கள் ஒன்றை நிர்ணயிக்கும் வரை "பின்தொடர்தல் இல்லை" தாவலில் இருக்கும். | iv/17 |
| `leads.outcomeSheet.savedNoFollowup` | Saved. No follow-up scheduled — the lead is in the No follow-up tab. | சேமிக்கப்பட்டது. பின்தொடர்தல் நிர்ணயிக்கப்படவில்லை — லீட் "பின்தொடர்தல் இல்லை" தாவலில் உள்ளது. | iv/17 |
| digest text (database, `run_lead_followup_notifications`) | …Open Daily Follow Up. | (English only today, as before; the digest body is not translated) | digest rename |
