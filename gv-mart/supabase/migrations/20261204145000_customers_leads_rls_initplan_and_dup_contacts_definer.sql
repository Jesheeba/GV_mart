-- Context (2026-11-03 Disk IO incident, continued investigation): EVERY policy on public.customers
-- and public.leads (all 12, all commands -- SELECT, UPDATE, INSERT, and the ALL-command
-- customers_write_sales, which also governs SELECT) calls one or more of
-- current_org_id()/is_staff()/is_sales_staff()/current_customer_id()/current_technician_id()/
-- public."current_role"() as a BARE per-row call. Each is a STABLE, zero-argument,
-- session-invariant function (same result for the whole query/transaction) -- confirmed live for
-- every one of them, including is_sales_staff() and the custom current_role() (not checked in the
-- first round of this migration): both STABLE, SECURITY DEFINER, COST 100 (Postgres's generic
-- default), and both genuinely query public.profiles by auth.uid() (not free, not trivial, a real
-- per-call cost). A first version of this migration wrapped only the 3 customers SELECT policies
-- and the 3 leads SELECT policies -- live EXPLAIN after that version showed the plain customers
-- search query STILL doing a dominant-cost Seq Scan, traced to customers_write_sales (cmd ALL,
-- which Postgres's permissive-policy OR-combination applies to SELECT too) still bare-calling
-- current_org_id()/is_sales_staff() per row. This version wraps ALL 12 policies' bare calls, in
-- both USING and WITH CHECK wherever present, closing that gap. This migration does NOT change
-- who can see or write what -- only WHEN Postgres evaluates these calls (once per query via an
-- InitPlan, instead of once per row), which is what the companion index migration
-- (20261204150000_customer_search_dedupe_indexes.sql, applied AFTER this one) needs in order to
-- actually have a chance of being chosen over a seq scan.
--
-- (a) ALTER POLICY only -- same policy names, same roles, same commands, same meaning. Every
-- correlated/row-dependent reference (the EXISTS subquery's own join conditions in
-- customers_select_own_technician, and every column-to-column comparison like org_id/id/owner_id)
-- is left exactly as-is; only the bare, zero-argument, session-invariant function calls are
-- wrapped.
alter policy customers_select_own on public.customers
  using (id = (select public.current_customer_id()));

alter policy customers_select_own_technician on public.customers
  using (
    exists (
      select 1
      from public.service_tickets t
      join public.appointments a on (a.ticket_id = t.id)
      where t.customer_id = customers.id
        and a.technician_id = (select public.current_technician_id())
    )
  );

alter policy customers_select_staff on public.customers
  using ((org_id = (select public.current_org_id())) and (select public.is_staff()));

alter policy customers_update_own on public.customers
  using (id = (select public.current_customer_id()));

alter policy customers_write_operation_admin on public.customers
  using ((org_id = (select public.current_org_id())) and ((select public."current_role"()) = 'operation_admin'::user_role))
  with check ((org_id = (select public.current_org_id())) and ((select public."current_role"()) = 'operation_admin'::user_role));

alter policy customers_write_sales on public.customers
  using ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()))
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

alter policy leads_insert_own_technician on public.leads
  with check ((owner_id = (select public.current_technician_id())) and (status = 'new'::lead_status));

alter policy leads_insert_sales on public.leads
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

alter policy leads_select_own_customer on public.leads
  using (customer_id = (select public.current_customer_id()));

alter policy leads_select_own_technician on public.leads
  using (owner_id = (select public.current_technician_id()));

alter policy leads_select_staff on public.leads
  using ((org_id = (select public.current_org_id())) and (select public.is_staff()));

alter policy leads_update_sales on public.leads
  using ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()))
  with check ((org_id = (select public.current_org_id())) and (select public.is_sales_staff()));

-- (c) find_duplicate_contacts: SECURITY DEFINER (so the caller's own RLS policy on customers no
-- longer gets evaluated per row on top of this function's own already-present org/is_test
-- filters), set search_path = '' with every object schema-qualified (pg_catalog is always
-- implicitly searched regardless, so lower/btrim/coalesce/count below remain resolvable; every
-- public-schema object was already written schema-qualified before this change and remains so).
-- The is_staff() gate and the org_id filter on BOTH customers and leads are unchanged in effect
-- -- still exactly what decides whether a row is returned, just no longer duplicated by RLS on
-- top. is_test handling on both tables is unchanged. Return shape UNCHANGED from the live
-- version -- all 8 columns (source, id, name, mobile, email, created_at, ticket_count,
-- invoice_count) kept exactly as-is, per explicit owner instruction (2026-11-03): CREATE OR
-- REPLACE requires the argument types AND return type to stay identical to the live signature --
-- confirmed this holds here (same 2-arg signature, same 8-column return table), so no DROP
-- FUNCTION is needed; changing SECURITY DEFINER/search_path alone never requires a DROP.
create or replace function public.find_duplicate_contacts(p_mobile text default null::text, p_email text default null::text)
returns table(source text, id uuid, name text, mobile text, email text, created_at timestamp with time zone, ticket_count bigint, invoice_count bigint)
language plpgsql
security definer
stable
set search_path to ''
as $function$
declare
  v_org_id uuid := public.current_org_id();
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  if v_mobile_key is null and v_email = '' then
    return;
  end if;

  return query
  select * from (
    select
      'customer'::text as source,
      c.id,
      c.name,
      c.mobile,
      c.email,
      c.created_at,
      (select count(*) from public.service_tickets t where t.customer_id = c.id)::bigint as ticket_count,
      (select count(*) from public.invoices i where i.customer_id = c.id)::bigint as invoice_count
    from public.customers c
    where c.org_id = v_org_id
      and not c.is_test
      and (
        (v_mobile_key is not null and public._mobile_key(c.mobile) = v_mobile_key)
        or (v_email <> '' and lower(c.email) = v_email)
      )
    union all
    select
      'lead'::text,
      l.id,
      l.name,
      l.mobile,
      null::text,
      l.created_at,
      0::bigint,
      0::bigint
    from public.leads l
    where l.org_id = v_org_id
      and not l.is_test
      and v_mobile_key is not null
      and public._mobile_key(l.mobile) = v_mobile_key
  ) matches
  order by created_at desc
  limit 10;
end;
$function$;

revoke all on function public.find_duplicate_contacts(text, text) from public, anon;
grant execute on function public.find_duplicate_contacts(text, text) to authenticated;
