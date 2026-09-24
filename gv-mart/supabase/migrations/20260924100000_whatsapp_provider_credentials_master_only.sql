-- Production-readiness audit 2026-09-23, Item 2: whatsapp_provider_credentials
-- holds the Wasi BSP connector's plaintext api_key and webhook_secret. Its
-- original RLS (20260825120000) let any is_staff() role read it — that
-- includes sales_admin, not just master/operation_admin. The table comment
-- "never selected from any client-side query in this codebase" is an
-- application-layer fact, not a security boundary: RLS is what actually
-- stops a signed-in sales_admin from running `select * from
-- whatsapp_provider_credentials` directly via PostgREST. Tightening both
-- policies to master-only, since these are live secrets, not day-to-day
-- operational config like whatsapp_business_numbers.
drop policy whatsapp_provider_credentials_select_staff on public.whatsapp_provider_credentials;
drop policy whatsapp_provider_credentials_write_ops on public.whatsapp_provider_credentials;

create policy whatsapp_provider_credentials_select_master on public.whatsapp_provider_credentials
  for select using (org_id = public.current_org_id() and public.is_master());
create policy whatsapp_provider_credentials_write_master on public.whatsapp_provider_credentials for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
