-- READ-ONLY snapshot for migration 20261115100200_customer_outstanding_report.sql. Run by hand, before and
-- after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/to_regclass/to_regtype so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\_\_TEST%' escape '\'
order by o.created_at asc
limit 1;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '20261115100200'
) as already_registered;

select
  to_regprocedure('public.report_customer_outstanding(uuid,int)') is not null as report_list_exists,
  to_regprocedure('public.report_customer_outstanding_detail(uuid)') is not null as report_detail_exists,
  to_regclass('public.invoices_org_customer_outstanding_idx') is not null as partial_index_exists;

select
  case when to_regprocedure('public.report_customer_outstanding(uuid,int)') is null then null
       else has_function_privilege('anon', 'public.report_customer_outstanding(uuid,int)', 'execute') end as report_list_anon,
  case when to_regprocedure('public.report_customer_outstanding_detail(uuid)') is null then null
       else has_function_privilege('anon', 'public.report_customer_outstanding_detail(uuid)', 'execute') end as report_detail_anon,
  case when to_regprocedure('public.report_customer_outstanding(uuid,int)') is null then null
       else has_function_privilege('authenticated', 'public.report_customer_outstanding(uuid,int)', 'execute') end as report_list_authenticated;

-- The live KPI-tile outstanding total (same predicate the new report RPCs reuse), org-wide, for
-- the real organisation -- cross-check this against the two Customer-Outstanding numbers reported
-- in the final report (owner's condition 3).
select
  (
    select jsonb_build_object(
      'amount', coalesce(sum(i.total - i.amount_paid), 0),
      'invoice_count', count(*))
    from public.invoices i
    where i.org_id = (select o.id from public.organizations o where o.name not like '\_\_TEST%' escape '\' order by o.created_at asc limit 1)
      and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
  ) as kpi_formula_outstanding;
