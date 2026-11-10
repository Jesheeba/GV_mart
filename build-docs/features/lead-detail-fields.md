# Feature: New lead-detail capture fields

## Purpose
Capture customer requirement, special description, lead-source-detail text, budget, tax-TDS status, and an optional report/document upload — none of which exist on `leads` today.

## Architecture
### Migration (additive, nullable — no backfill needed)
```sql
alter table leads
  add column customer_requirement text,
  add column special_description text,
  add column user_source text,
  add column budget numeric check (budget is null or budget >= 0),
  add column tds_status text check (tds_status is null or tds_status in ('applicable','not_applicable','to_be_confirmed')),
  add column report_storage_path text;
```
- Column named `tds_status`, label "TDS" — confirmed this is the same water-TDS domain concept used elsewhere in the app, so no renaming/disambiguation is needed (PLAN.md §3.1).
- `user_source` is distinct from `leads.source` (the structured masters-backed dropdown) — this is the free-text "how/where they heard about us" detail the spec calls out as possibly duplicating `source`; kept separate per spec's own "clarify whether this duplicates Lead source" note. UI copy should hint at the distinction so staff don't fill both redundantly.

### Storage
- New private bucket `lead-reports`, path `${orgId}/${leadId}/${uuid}.<ext>`.
- New RPC `record_lead_document(p_org_id uuid, p_lead_id uuid, p_storage_path text)` — SECURITY DEFINER, validates org/lead ownership, writes `leads.report_storage_path` (same pattern as `record_payment_proof`).
- Client: mirror `paymentProofs.ts` shape — `uploadLeadDocument(orgId, leadId, file)`; `leadDocumentSignedUrl(path)`.
- Server-side validation: MIME allowlist (pdf, doc, docx, xls, xlsx, jpg, jpeg, png — matches prototype's `accept`), max size (confirm limit with business before implementing — not specified yet).

## Impact map
- `NewLeadForm.tsx` — add `customer_requirement`, `special_description`, `user_source`, `budget`, `tax_tds_status` as optional fields; `leadSchema` (zod, in `@/lib/validation/automation`) gets matching optional/nullable rules.
- `LeadDetailPage.tsx` / `LeadDetailPanel.tsx` — render/edit these fields; add upload control for `report_storage_path`.
- `database.ts` generated types — regenerate or hand-patch (per memory: Docker unavailable, hand-patch `database.ts`) to include new columns.
- Water-TDS features elsewhere in the app (`water_tds_ppm`, `tds_before/after`, `product_tds_recommendations`) are unrelated tables — confirm UI copy/placement for this lead-level TDS dropdown doesn't get confused with those during implementation, but no column renaming needed; same domain concept, different granularity (lead-stage dropdown vs. measured ppm).
- No change to `assigned_to`, `kind`, `source`, `lead_activities`, `lead_followups`.

## Edge cases and failure modes
- Budget negative → rejected by DB check constraint + client validation.
- Upload of disallowed file type/oversized file → rejected server-side (RPC/storage policy), not just client-side.
- Lead deleted while upload in-flight → RPC's ownership check fails closed (no orphan write).
- Empty state: all new fields nullable, existing leads show blank, not an error.

## Acceptance criteria
- [ ] Customer requirement, Special description, User source/referred through, Budget, TDS (Tax), Upload report/document all appear on lead create and detail views.
- [ ] Budget stored as numeric, rejects negative values client- and server-side.
- [ ] TDS dropdown options: Select TDS, Applicable, Not applicable, To be confirmed (water-TDS concept, labeled plainly "TDS").
- [ ] Upload validates MIME type and size server-side before storing.
- [ ] Existing leads (pre-migration) render fine with all new fields blank.
