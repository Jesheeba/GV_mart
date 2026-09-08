-- PDF-generation piece of the supplier document-quote-request work
-- (compliance investigation, 2026-09-03): Wasi's outbound API has no
-- document/media send capability today, and a document-header WhatsApp
-- template needs manual submission via Wasi's own dashboard UI (their Hub
-- API has no template-submission endpoint) plus Meta approval, timeline
-- unknown, before any send code can consume this. This migration only adds
-- what PDF generation itself needs — it does not touch whatsapp_outbox,
-- sendMessage(), or the monthly RFQ trigger.

alter table public.purchase_quote_requests add column pdf_url text;

-- Public-read, same posture as product-photos/product-documents
-- (20260804091000): once wired up, Meta's servers need to fetch this URL
-- directly with no auth, so a signed URL (the ticket-photos/payment-proofs
-- pattern) won't work here. Written only by generate-quote-pdf, which uses
-- the service_role key and so bypasses RLS — no insert/update/delete policy
-- is needed for that; the browser only ever reads.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('supplier-quote-pdfs', 'supplier-quote-pdfs', true, 2097152, array['application/pdf'])
on conflict (id) do nothing;

create policy supplier_quote_pdfs_read_public on storage.objects for select using (bucket_id = 'supplier-quote-pdfs');
