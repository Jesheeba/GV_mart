-- Customers list performance fix: getCustomerFilterCounts() (services/customers.ts)
-- ran on every single Customers-list page load and downloaded entire raw row sets
-- (every amc_contracts.customer_id, every customers.id older than the dormancy
-- window, every invoices/service_tickets.customer_id in that window) just to count
-- them in JavaScript -- no `count: "exact", head: true`, no server-side aggregate.
-- This was the single slowest page in the app (~7s to settle vs ~2s for the
-- Dashboard) and only gets worse as the org's history grows. Same anti-pattern,
-- same fix shape as the reports SQL aggregation phase (20261009100000 etc.):
-- move the counting into Postgres and return four numbers instead of thousands
-- of rows.
--
-- ADDITIVE ONLY: nothing dropped or replaced. The old client-side path in
-- services/customers.ts keeps working until the hook is switched over to this.
--
-- Faithful parity with the current JS (idsWithAmc / idsByAmcStatus / idsDormant):
--   * hasAmc / amcDueSoon do NOT exclude is_test customers (same as today -- only
--     `total` does). Not introducing a behavior change beyond the performance fix.
--   * dormant: registered (created_at) before the 180-day window, with no invoice
--     or service ticket inside it -- exact same definition, computed as NOT EXISTS
--     instead of a client-side set-difference over two downloaded id lists.

create index if not exists invoices_org_customer_created_idx on public.invoices (org_id, customer_id, created_at);
create index if not exists service_tickets_org_customer_created_idx on public.service_tickets (org_id, customer_id, created_at);

create or replace function public.customer_filter_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public._report_org();
  v_cutoff timestamptz := now() - interval '180 days';
  v_total integer;
  v_has_amc integer;
  v_amc_due_soon integer;
  v_dormant integer;
begin
  select count(*) into v_total
  from public.customers
  where org_id = v_org and is_test = false;

  select count(distinct customer_id) into v_has_amc
  from public.amc_contracts
  where org_id = v_org;

  select count(distinct customer_id) into v_amc_due_soon
  from public.amc_contracts
  where org_id = v_org and status = 'due_soon';

  select count(*) into v_dormant
  from public.customers c
  where c.org_id = v_org
    and c.created_at < v_cutoff
    and not exists (
      select 1 from public.invoices i
      where i.org_id = v_org and i.customer_id = c.id and i.created_at >= v_cutoff
    )
    and not exists (
      select 1 from public.service_tickets t
      where t.org_id = v_org and t.customer_id = c.id and t.created_at >= v_cutoff
    );

  return jsonb_build_object(
    'total', v_total,
    'hasAmc', v_has_amc,
    'amcDueSoon', v_amc_due_soon,
    'dormant', v_dormant
  );
end;
$$;

revoke all on function public.customer_filter_counts() from public, anon;
grant execute on function public.customer_filter_counts() to authenticated;
