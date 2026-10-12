# Tamil strings pending review (KPI tiles, Step 3)

English is the source text. **Every Tamil string below is a DRAFT** until a Tamil speaker signs it off. Delete a row once reviewed.
67 new keys, all under `kpi.*` in `src/lib/i18n/en.json` and `ta.json`. `{{...}}` placeholders must stay as written.

Points to settle with the reviewer:
- "லீட்" (lead), "டிக்கெட்" (ticket), "டைல்" (tile) are transliterations, as elsewhere in the app. Is a native word preferred for any?
- "SLA", "AMC", "GST" are kept in Latin script, matching the existing `ta.json`.
- "பண லாபம்" for *cash profit* and "பொருள் லாபம்" for *item margin*: do these read as two distinct ideas to an owner?
- "வசூலானது" for *collected* and "நிலுவைத் தொகை" for *outstanding*.
- Sentence order of the sub-lines with two numbers (`kpi.resolved.sub`, `kpi.leadWon.sub`, `kpi.collected.sub`, `kpi.repeat.sub`).
- Help texts (`*.help`) are the longest strings; check they fit on a phone and read naturally.

| Key | English | Tamil (draft) |
|---|---|---|
| `kpi.group.sales` | Sales | விற்பனை |
| `kpi.group.service` | Service | சேவை |
| `kpi.group.moneyOut` | Spend and profit | செலவு மற்றும் லாபம் |
| `kpi.invoiced.title` | Revenue (excl. GST) | வருவாய் (GST நீங்கலாக) |
| `kpi.invoiced.sub` | Incl. GST: {{amount}} | GST உட்பட: {{amount}} |
| `kpi.invoiced.help` | What was billed in this period, before GST. This headline used to show the amount including GST; that figure is still shown underneath. | இந்தக் காலத்தில் வழங்கிய பில்களின் தொகை, GST நீங்கலாக. இந்த முதன்மை எண் முன்பு GST உட்பட காட்டியது; அந்த எண் கீழே தொடர்ந்து காட்டப்படுகிறது. |
| `kpi.collected.title` | Collected so far | இதுவரை வசூலானது |
| `kpi.collected.sub` | of {{total}} billed | {{total}} பில்லில் |
| `kpi.collected.help` | Money received so far against this period's bills. It is not the cash received during the period. | இந்தக் காலத்தின் பில்களுக்கு இதுவரை பெற்ற தொகை. இது இந்தக் காலத்தில் கையில் வந்த பணம் அல்ல. |
| `kpi.outstanding.title` | Outstanding | நிலுவைத் தொகை |
| `kpi.outstanding.sub` | {{count}} unpaid bills · oldest {{date}} | {{count}} செலுத்தப்படாத பில்கள் · பழையது {{date}} |
| `kpi.outstanding.none` | Nothing outstanding | நிலுவை எதுவும் இல்லை |
| `kpi.outstanding.help` | Unpaid and part-paid bills of any date, as of now. | எந்தத் தேதியிலுள்ள செலுத்தப்படாத மற்றும் பகுதி செலுத்திய பில்கள், இப்போதைய நிலை. |
| `kpi.spend.title` | Spend | செலவு |
| `kpi.spend.sub` | Excluding stock purchases: {{amount}} | பொருள் கொள்முதல் நீங்கலாக: {{amount}} |
| `kpi.spend.help` | Everything paid out in this period, by the date it was recorded. | இந்தக் காலத்தில் பதிவான அனைத்துச் செலவுகளும். |
| `kpi.cashProfit.title` | Cash profit | பண லாபம் |
| `kpi.cashProfit.help` | Money collected (excl. GST) minus spend. Stock purchases count when they are billed, not when the stock is sold. | வசூலான தொகை (GST நீங்கலாக) கழித்தல் செலவு. பொருள் கொள்முதல் பில் செய்த நேரத்தில் கணக்கில் வரும், விற்கும்போது அல்ல. |
| `kpi.itemMargin.title` | Item margin | பொருள் லாபம் |
| `kpi.itemMargin.sub` | {{percent}}% margin | {{percent}}% லாப விகிதம் |
| `kpi.itemMargin.subWithCost` | {{percent}}% on items with a cost | விலை பதிவான பொருட்களில் {{percent}}% |
| `kpi.itemMargin.help` | Selling price minus the cost price of the items sold. Items with no cost price recorded are left out, not counted as free. | விற்பனை விலை கழித்தல் விற்ற பொருட்களின் கொள்முதல் விலை. கொள்முதல் விலை பதிவாகாத பொருட்கள் சேர்க்கப்படாது, இலவசமாகக் கணக்கிடப்படாது. |
| `kpi.costMissing.badge` | Cost missing on {{count}} items | {{count}} பொருட்களுக்கு கொள்முதல் விலை இல்லை |
| `kpi.streams.title` | Where revenue comes from | வருவாய் எங்கிருந்து வருகிறது |
| `kpi.streams.product` | Products | பொருட்கள் |
| `kpi.streams.spareCounter` | Spares (counter sales) | உதிரி பாகங்கள் (கவுண்டர் விற்பனை) |
| `kpi.streams.service` | Service | சேவை |
| `kpi.streams.amc` | AMC | AMC |
| `kpi.streams.rental` | Rental | வாடகை |
| `kpi.streams.gstAdjustments` | GST and adjustments | GST மற்றும் சரிசெய்தல்கள் |
| `kpi.streams.total` | Total billed (incl. GST) | மொத்த பில் தொகை (GST உட்பட) |
| `kpi.streams.note` | Spares used on a service visit count as Service. | சேவை வருகையில் பயன்படுத்தும் உதிரி பாகங்கள் சேவையில் கணக்கிடப்படும். |
| `kpi.streams.help` | Total billed in this period split by where it came from. The rows add up to the total. | இந்தக் காலத்தின் மொத்த பில் தொகை, எங்கிருந்து வந்தது என்று பிரித்துக் காட்டப்படுகிறது. வரிசைகளின் கூட்டுத்தொகை மொத்தத்திற்குச் சமம். |
| `kpi.unitsSold.title` | Units sold | விற்ற எண்ணிக்கை |
| `kpi.unitsSold.help` | Number of products sold on counter and product bills in this period. | இந்தக் காலத்தில் கவுண்டர் மற்றும் பொருள் பில்களில் விற்ற பொருட்களின் எண்ணிக்கை. |
| `kpi.avgSale.title` | Average sale | சராசரி விற்பனை |
| `kpi.avgSale.help` | Average value of a product or counter sale bill in this period, including GST. | இந்தக் காலத்தில் பொருள் அல்லது கவுண்டர் விற்பனை பில்லின் சராசரி மதிப்பு, GST உட்பட. |
| `kpi.leadsNew.title` | New leads | புதிய லீட்கள் |
| `kpi.leadsNew.help` | Leads that arrived in this period. | இந்தக் காலத்தில் வந்த லீட்கள். |
| `kpi.leadWon.title` | Lead to sale | லீட்டிலிருந்து விற்பனை |
| `kpi.leadWon.sub` | {{won}} of {{total}} leads | {{total}} லீட்களில் {{won}} |
| `kpi.leadWon.help` | Of the leads that arrived in this period, the share that became a sale so far. Lost leads count in the total. | இந்தக் காலத்தில் வந்த லீட்களில் இதுவரை விற்பனையாக மாறியவை. இழந்த லீட்களும் மொத்தத்தில் சேரும். |
| `kpi.openTickets.title` | Open tickets | திறந்த டிக்கெட்டுகள் |
| `kpi.openTickets.sub` | {{urgent}} urgent · {{past}} past SLA | {{urgent}} அவசரம் · {{past}} SLA கடந்தவை |
| `kpi.openTickets.help` | Service tickets that are open, assigned or in progress right now. | இப்போது திறந்த, ஒதுக்கப்பட்ட அல்லது நடைபெறும் சேவை டிக்கெட்டுகள். |
| `kpi.resolved.title` | Fixed within 24 hours | 24 மணி நேரத்தில் தீர்வு |
| `kpi.resolved.sub` | {{resolved}} of {{completed}} completed | முடிந்த {{completed}} இல் {{resolved}} |
| `kpi.resolved.help` | Of the tickets raised in this period and now completed, the share completed within 24 hours. | இந்தக் காலத்தில் பதிவாகி இப்போது முடிந்த டிக்கெட்டுகளில் 24 மணி நேரத்திற்குள் முடிந்தவை. |
| `kpi.rating.title` | Customer rating | வாடிக்கையாளர் மதிப்பீடு |
| `kpi.rating.sub` | {{count}} ratings · {{low}} below 4.5 | {{count}} மதிப்பீடுகள் · {{low}} 4.5 க்குக் கீழ் |
| `kpi.rating.help` | Average star rating of visits in this period. | இந்தக் காலத்தில் நடந்த வருகைகளின் சராசரி நட்சத்திர மதிப்பீடு. |
| `kpi.amc.title` | AMC contracts | AMC ஒப்பந்தங்கள் |
| `kpi.amc.sub` | {{count}} due for renewal | {{count}} புதுப்பிக்க வேண்டியவை |
| `kpi.amc.help` | AMC contracts active today, and how many are in their renewal window. | இன்று செயலில் உள்ள AMC ஒப்பந்தங்கள், அவற்றில் புதுப்பிக்கும் காலத்தில் உள்ளவை. |
| `kpi.repeat.title` | Repeat buyers | மீண்டும் வாங்குபவர்கள் |
| `kpi.repeat.sub` | {{repeat}} of {{buying}} buyers | {{buying}} வாங்குபவர்களில் {{repeat}} |
| `kpi.repeat.help` | Of the customers who bought in this period, the share who had bought before. | இந்தக் காலத்தில் வாங்கிய வாடிக்கையாளர்களில் முன்பும் வாங்கியவர்கள். |
| `kpi.todaySales` | Today's sales (excl. GST) | இன்றைய விற்பனை (GST நீங்கலாக) |
| `kpi.live` | Live | நேரடி |
| `kpi.period` | Period: {{from}} – {{to}} (IST) | காலம்: {{from}} – {{to}} (IST) |
| `kpi.noSales` | No sales in this period yet | இந்தக் காலத்தில் இன்னும் விற்பனை இல்லை |
| `kpi.noData` | No data yet | இன்னும் தரவு இல்லை |
| `kpi.error` | Could not load the tiles | டைல்களை ஏற்ற முடியவில்லை |
| `kpi.helpButton` | What does this mean? | இதன் பொருள் என்ன? |
| `kpi.exactAmount` | Exact: {{amount}} | துல்லியமாக: {{amount}} |
| `kpi.updating` | Updating… | புதுப்பிக்கிறது… |
| `kpi.toggleGroup` | Show or hide {{group}} | {{group}} ஐக் காட்டு அல்லது மறை |
