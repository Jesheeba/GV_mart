-- Rollback for 20261201110000_lead_edit_details.sql.

drop function if exists public.update_lead_details(uuid, text, text, text, text, text, text, text);

drop trigger if exists audit_lead_edit_fields on public.leads;
drop function if exists public.audit_lead_edit_fields();

alter table public.leads drop constraint if exists leads_alternate_mobile_format_check;
alter table public.leads drop column if exists address_text;
alter table public.leads drop column if exists alternate_mobile;
