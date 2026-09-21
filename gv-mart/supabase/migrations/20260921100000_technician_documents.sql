-- Item 1 (2026-09-21) — technician KYC documents: a photo of the Aadhar card
-- and Driving Licence, not a typed number (owner decision — a photo of the
-- physical card is what's actually collected in practice, and avoids storing
-- a bare 12-digit Aadhar number in a plain queryable column). Same private-
-- bucket + storage_path + signed-URL-on-demand posture as ticket-photos/
-- payment-proofs (20260804170000_gate_assignment_on_product.sql,
-- 20260807092000_payment_proofs.sql) — the path lives directly on
-- `technicians` (at most one of each document per technician, unlike those
-- one-to-many photo tables) and is never rendered inline; an admin has to
-- explicitly request a signed URL to view it. Visible/editable to whichever
-- roles can already manage technicians (technicians_write_ops /
-- admin-create-technician's master/operation_admin gate) — no narrower
-- restriction than the rest of the technician record. No delete policy on
-- the bucket, matching payment-proofs' permanent-record posture — replacing
-- a document just overwrites the column with a new path.

alter table public.technicians
  add column aadhar_document_path text,
  add column driving_licence_document_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('technician-documents', 'technician-documents', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy technician_documents_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'technician-documents' and public.is_ops_staff()
);
create policy technician_documents_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'technician-documents' and public.is_ops_staff()
);
