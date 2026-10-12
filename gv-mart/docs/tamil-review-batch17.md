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
| `masters.tabs.postService` / `masters.overview.postServiceDesc` | Post-service calls / Call the customer after a job; outcomes | சேவைக்குப் பிந்தைய அழைப்புகள் / வேலைக்குப் பிறகு வாடிக்கையாளரை அழைக்க; முடிவுகள் | 13 |
| `masters.postService.*` (settings card) | Post-service follow-up call; ON/OFF; Call after (days); Who gets the call; All sales staff; Skip if already called within (days); Ticket types that get a call; hints | சேவைக்குப் பிந்தைய பின்தொடர் அழைப்பு; இயக்கம்/நிறுத்தம்; எத்தனை நாட்கள் கழித்து அழைக்க; அழைப்பு யாருக்கு; அனைத்து விற்பனை ஊழியர்கள்; … (see ta.json) | 13 |
| `masters.postService.*` (outcomes list) | Call outcomes; Outcome (English/Tamil); Call again; Alert master; Add outcome; cannot-delete message | அழைப்பு முடிவுகள்; முடிவு (ஆங்கிலம்/தமிழ்); மீண்டும் அழை; மாஸ்டருக்கு எச்சரிக்கை; முடிவைச் சேர் … (see ta.json) | 13 |
| `leads.postService.*` (Daily Follow Up card + sheet) | Post-service call; Log call; How did the call go?; What was discussed; Call again on; saved messages; alert hint | சேவைக்குப் பிந்தைய அழைப்பு; அழைப்பைப் பதிவிடு; அழைப்பு எப்படி இருந்தது?; என்ன பேசப்பட்டது; மீண்டும் அழைக்கும் நாள் … (see ta.json) | 13 |
| `service.detail.postServiceCalls` | Post-service calls | சேவைக்குப் பிந்தைய அழைப்புகள் | 13 |
| seed outcomes (`post_service_outcomes.label_ta`) | Satisfied — all good / Problem not solved / Could not reach — try again / Asked to call later / No call needed | திருப்தி — எல்லாம் சரி / பிரச்சனை தீரவில்லை / தொடர்பு கொள்ள முடியவில்லை — மீண்டும் முயற்சி / பிறகு அழைக்கச் சொன்னார் / அழைப்பு தேவையில்லை | 13 |
| digest text (database) | …N post-service call(s) due. | (English only, like the rest of the digest body) | 13 |
| `customers.testBadge` | Test | சோதனை | batch-2 item 5 |
| `masters.products.installationCharge` / `...Hint` | Installation charge (technician incentive per unit) / Not billed to the customer | நிறுவல் கட்டணம் (ஒரு யூனிட்டிற்கு தொழில்நுட்பர் ஊக்கத்தொகை) / வாடிக்கையாளரிடம் வசூலிக்கப்படாது | batch-2 item 3 |
| `service.detail.installCharge.*` | Installation incentive (per unit); Not set; internal, not billed; invalid amount | நிறுவல் ஊக்கத்தொகை (ஒரு யூனிட்டிற்கு); அமைக்கப்படவில்லை; உள் பயன்பாடு… | batch-2 item 3 |
| `technician.onsite.installIncentive` | Installation incentive: {{amount}} per unit (needs the master's approval) | நிறுவல் ஊக்கத்தொகை: ஒரு யூனிட்டிற்கு {{amount}} (மாஸ்டரின் ஒப்புதல் தேவை) | batch-2 item 3 |
| `hr.incentives.credits.*`, `hr.incentives.creditsEarned` | Installation incentives to approve; Approve; Void; Reason for voiding; Installation (per ticket) | ஒப்புதலுக்கான நிறுவல் ஊக்கத்தொகைகள்; ஒப்புதல்; ரத்து செய்; ரத்து செய்வதற்கான காரணம்; நிறுவல் (டிக்கெட்டிற்கு) | batch-2 item 3 |
| `settings.reviewIncentivesEnabled` / `...Hint` | Review incentives (OFF by default) / Off: no review incentive rule, no review-time allowance, no claim-rate flags... | மதிப்புரை ஊக்கத்தொகை (இயல்பாக நிறுத்தம்) / … (see ta.json) | batch-2 item 6 |
| `settings.reviewLinkMinStars` (relabelled) | Low-rating alert below (stars) | குறைந்த மதிப்பீட்டு எச்சரிக்கை (நட்சத்திரங்களுக்கு கீழ்) | batch-2 item 6 |
