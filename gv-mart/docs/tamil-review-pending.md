# Tamil strings pending review by a Tamil speaker

Drafted by Claude alongside the reports SQL-aggregation work (branch `fix/reports-sql-aggregation`).
The English is approved; the Tamil below is a draft until a Tamil speaker signs it off. Once reviewed,
delete the entry (and keep `src/lib/i18n/reportsNotes.test.ts` in step).

| Key | English (approved) | Tamil (draft) |
|---|---|---|
| `reports.insights.funnelNote` | Stages come from each lead’s logged stage history. A lead with no recorded history can’t be placed at a stage, so it appears only in the totals (or as Lost). | நிலைகள் ஒவ்வொரு லீடின் பதிவு செய்யப்பட்ட நிலை வரலாற்றிலிருந்து கணக்கிடப்படுகின்றன. நிலை வரலாறு பதிவாகாத லீட்டை ஒரு நிலையில் வைக்க முடியாது; அது மொத்த எண்ணிக்கையில் மட்டும் (அல்லது இழந்ததாக) தோன்றும். |
| `reports.salesService.revenueByTypeNote` | Count = invoices. Service = invoices raised from a service visit, at their full GST-inclusive total. Qty = units sold for Sales; equals count for the others. Average = revenue ÷ count. | எண்ணிக்கை = இன்வாய்ஸ்கள். சேவை = சேவை வருகையிலிருந்து உருவான இன்வாய்ஸ்கள், GST உட்பட முழு தொகையில். அளவு = விற்பனைக்கு விற்ற அலகுகள்; மற்றவற்றுக்கு எண்ணிக்கைக்குச் சமம். சராசரி = வருவாய் ÷ எண்ணிக்கை. |
| `reports.salesService.ofWhichGst` | Of which GST | இதில் GST |
| `reports.salesService.visitsCount` | {{count}} visits | {{count}} வருகைகள் |
