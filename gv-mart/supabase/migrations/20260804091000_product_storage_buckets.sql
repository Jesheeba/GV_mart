-- Product Enquiry rebuild (2026-08-04), Phase 1 continued: Storage buckets
-- for product photos/documents. No Supabase Storage bucket exists anywhere
-- in this codebase today — this is genuinely new infra, not an extension
-- of an existing pattern. Declared via migration (not supabase/config.toml,
-- which only seeds local dev) so both local and deployed environments get
-- the same buckets.
--
-- Public-read (confirmed with client): product photos/documents are
-- marketing collateral, not private customer data, so a plain public URL
-- is simplest (no signed-URL refresh logic needed for <img>/<a> tags).
-- Writes are restricted to is_master(), matching every other admin-master
-- write gate in this schema. Object path convention is
-- {org_id}/{product_id}/{uuid}-{filename} so a future tightened policy
-- could scope by org via the path even though today's policy is bucket-wide
-- (storage.objects has no org_id column of its own to filter on directly).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-documents', 'product-documents', true, 10485760, array['application/pdf'])
on conflict (id) do nothing;

create policy product_photos_read_public on storage.objects for select using (bucket_id = 'product-photos');
create policy product_photos_write_master on storage.objects for insert to authenticated with check (
  bucket_id = 'product-photos' and public.is_master()
);
create policy product_photos_update_master on storage.objects for update to authenticated using (
  bucket_id = 'product-photos' and public.is_master()
);
create policy product_photos_delete_master on storage.objects for delete to authenticated using (
  bucket_id = 'product-photos' and public.is_master()
);

create policy product_documents_read_public on storage.objects for select using (bucket_id = 'product-documents');
create policy product_documents_write_master on storage.objects for insert to authenticated with check (
  bucket_id = 'product-documents' and public.is_master()
);
create policy product_documents_update_master on storage.objects for update to authenticated using (
  bucket_id = 'product-documents' and public.is_master()
);
create policy product_documents_delete_master on storage.objects for delete to authenticated using (
  bucket_id = 'product-documents' and public.is_master()
);
