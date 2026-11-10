-- Lead Dashboard Enhancement, feature 4 (lead-detail-fields) —
-- build-docs/features/lead-detail-fields.md. Additive, nullable columns on
-- `leads` + a private storage bucket + RPC for the optional report/document
-- upload, same "private bucket + SECURITY DEFINER-only write" posture as
-- payment_proofs (20260807092000_payment_proofs.sql).
--
-- tds_status is the SAME water-TDS domain concept used elsewhere in the app
-- (water_tds_ppm, product_tds_recommendations etc.) — just a lead-stage
-- dropdown rather than a measured ppm value. Confirmed with the business
-- 2026-11-10; no renaming needed (see build-docs/MEMORY.md).

alter table public.leads
  add column customer_requirement text,
  add column special_description text,
  add column user_source text,
  add column budget numeric check (budget is null or budget >= 0),
  add column when_needed text,
  add column tds_status text check (tds_status is null or tds_status in ('applicable', 'not_applicable', 'to_be_confirmed')),
  add column report_storage_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'lead-reports', 'lead-reports', false, 10485760,
  array['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'image/jpeg', 'image/png']
)
on conflict (id) do nothing;

create policy lead_reports_storage_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'lead-reports' and public.is_sales_staff()
);
create policy lead_reports_storage_select on storage.objects for select to authenticated using (
  bucket_id = 'lead-reports' and public.is_staff()
);

-- record_lead_document: only the storage path is trusted from the client
-- (the upload itself already went through the bucket's own insert policy
-- above); this just links it to the lead after checking the caller is sales
-- staff in the lead's own org. Single file per lead — the new path replaces
-- any previous one (v1 scope, see build-docs/features/lead-detail-fields.md).
create or replace function public.record_lead_document(
  p_org_id uuid,
  p_lead_id uuid,
  p_storage_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead leads;
begin
  if not public.is_sales_staff() then
    raise exception 'record_lead_document: caller is not sales staff';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'record_lead_document: org mismatch';
  end if;
  if nullif(btrim(p_storage_path), '') is null then
    raise exception 'record_lead_document: storage_path is required';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and org_id = p_org_id;
  if v_lead.id is null then
    raise exception 'record_lead_document: lead % not found', p_lead_id;
  end if;

  update public.leads set report_storage_path = p_storage_path, updated_at = now() where id = p_lead_id;

  return jsonb_build_object('ok', true, 'lead_id', p_lead_id);
end;
$$;

grant execute on function public.record_lead_document(uuid, uuid, text) to authenticated;
