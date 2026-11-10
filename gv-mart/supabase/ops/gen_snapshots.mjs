// Generator for the 7 READ-ONLY .snapshot.sql files, matching the
// feat/customer-water-profile convention: to_regclass/to_regprocedure/
// to_regtype guards throughout so each runs cleanly before AND after its
// apply script, at any time (no 11:00 IST gate -- nothing here writes).
import fs from 'fs';
import path from 'path';

const OPSDIR = import.meta.dirname;
const HEADER = (version, title) => `-- READ-ONLY snapshot for migration ${version}_${title}.sql. Run by hand, before and
-- after the GO APPLY script. Nothing here writes anything. Safe to run at any time, including
-- before 11:00 IST. Every reference to an object this migration creates is guarded with
-- to_regprocedure/to_regclass/to_regtype so this runs cleanly before the apply.

-- Real-organisation fingerprint (must match 6f891cf85011f08c2f22fb4a208d21bd before you run anything).
select md5(o.id::text || '|' || o.name) as org_fingerprint, o.id, o.name, o.created_at
from public.organizations o
where o.name not like '\\_\\_TEST%' escape '\\'
order by o.created_at asc
limit 1;

-- Whether supabase_migrations.schema_migrations already has this version registered.
select exists(
  select 1 from supabase_migrations.schema_migrations where version = '${version}'
) as already_registered;
`;

function write(version, title, body) {
  fs.writeFileSync(path.join(OPSDIR, `${version}_${title}.snapshot.sql`), HEADER(version, title) + body);
}

write('20261115100000', 'customer_outstanding_reminders_schema', `
-- Whether the new objects already exist (expect false/NULL before, true/not-null after).
select
  to_regclass('public.customer_outstanding_reminders') is not null as table_exists,
  to_regtype('public.customer_outstanding_reminder_status') is not null as status_type_exists;

-- RLS + privilege state, guarded against the table being absent.
select
  case when to_regclass('public.customer_outstanding_reminders') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.customer_outstanding_reminders')) end as rls_enabled,
  case when to_regclass('public.customer_outstanding_reminders') is null then null
       else has_table_privilege('anon', 'public.customer_outstanding_reminders', 'SELECT') end as select_by_anon,
  case when to_regclass('public.customer_outstanding_reminders') is null then null
       else has_table_privilege('authenticated', 'public.customer_outstanding_reminders', 'SELECT') end as select_by_authenticated,
  case when to_regclass('public.customer_outstanding_reminders') is null then null
       else exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_outstanding_reminders' and policyname = 'customer_outstanding_reminders_select_master') end as select_policy_exists;
`);

write('20261115100100', 'customer_outstanding_links_schema', `
select to_regclass('public.customer_outstanding_links') is not null as table_exists;

select
  case when to_regclass('public.customer_outstanding_links') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.customer_outstanding_links')) end as rls_enabled,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else has_table_privilege('anon', 'public.customer_outstanding_links', 'SELECT') end as select_by_anon,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else has_table_privilege('authenticated', 'public.customer_outstanding_links', 'SELECT') end as select_by_authenticated,
  case when to_regclass('public.customer_outstanding_links') is null then null
       else exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'customer_outstanding_links' and policyname = 'customer_outstanding_links_select_master') end as select_policy_exists;
`);

write('20261115100200', 'customer_outstanding_report', `
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
    where i.org_id = (select o.id from public.organizations o where o.name not like '\\_\\_TEST%' escape '\\' order by o.created_at asc limit 1)
      and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
      and not public.is_test_customer(i.customer_id)
  ) as kpi_formula_outstanding;
`);

write('20261115100300', 'customer_outstanding_rpcs', `
select
  to_regprocedure('public.create_customer_outstanding_reminder(uuid,timestamptz,text,uuid,numeric)') is not null as create_reminder_exists,
  to_regprocedure('public.reschedule_customer_outstanding_reminder(uuid,timestamptz,text)') is not null as reschedule_reminder_exists,
  to_regprocedure('public.close_customer_outstanding_reminder(uuid)') is not null as close_reminder_exists,
  to_regprocedure('public.cancel_customer_outstanding_reminder(uuid,text)') is not null as cancel_reminder_exists,
  to_regprocedure('public.create_customer_outstanding_task(uuid,uuid,text,date,uuid,numeric)') is not null as create_task_exists,
  to_regprocedure('public.close_outstanding_reminders_if_zero(uuid)') is not null as close_if_zero_exists;
`);

write('20261115100400', 'tasks_customer_outstanding_guard', `
-- The live tasks_select_internal policy text (before: expected post-P3 shape without the
-- ref_type carve-out; after: with it).
select qual from pg_policies where schemaname = 'public' and tablename = 'tasks' and policyname = 'tasks_select_internal';

select to_regprocedure('public._guard_customer_outstanding_task_ref()') is not null as guard_function_exists;

select exists (
  select 1 from pg_trigger where tgname = 'aaa_guard_customer_outstanding_task_ref' and tgrelid = 'public.tasks'::regclass and not tgisinternal
) as guard_trigger_exists;
`);

write('20261115110000', 'expense_categories_schema', `
select
  to_regclass('public.expense_categories') is not null as table_exists,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses' and column_name = 'category_id') as category_id_column_exists;

select
  case when to_regclass('public.expense_categories') is null then null
       else (select relrowsecurity from pg_class where oid = to_regclass('public.expense_categories')) end as rls_enabled,
  case when to_regclass('public.expense_categories') is null then null
       else has_table_privilege('anon', 'public.expense_categories', 'SELECT') end as select_by_anon;

-- The live expense_category enum values (must be unchanged by this migration -- additive only).
select array_agg(enumlabel order by enumsortorder) as expense_category_enum_values
from pg_enum where enumtypid = 'public.expense_category'::regtype;

-- NOT part of the before/after pair above (the planner must resolve public.expense_categories to
-- plan this query at all, so it would fail the whole batch before the table exists). Run this one
-- query BY ITSELF, AFTER the apply, to see the real organisation's seeded system-category count
-- (expect exactly 12):
--   select count(*) from public.expense_categories ec
--   where ec.org_id = (select o.id from public.organizations o where o.name not like '__TEST%' escape '' order by o.created_at asc limit 1)
--     and ec.is_system;
`);

write('20261115110100', 'expense_categories_rpcs', `
select
  to_regprocedure('public.create_expense_category(text)') is not null as create_exists,
  to_regprocedure('public.rename_expense_category(uuid,text)') is not null as rename_exists,
  to_regprocedure('public.deactivate_expense_category(uuid)') is not null as deactivate_exists,
  to_regprocedure('public.delete_expense_category(uuid)') is not null as delete_exists;
`);

console.log('all 7 snapshot scripts written');
