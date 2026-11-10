drop function if exists public.report_customer_outstanding(uuid, int);
drop function if exists public.report_customer_outstanding_detail(uuid);
drop index if exists public.invoices_org_customer_outstanding_idx;
