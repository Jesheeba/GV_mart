-- ROLLBACK for 20261204145000_customers_leads_rls_initplan_and_dup_contacts_definer.sql
-- Restores all 12 policies to their exact pre-migration USING/WITH CHECK expressions (the live
-- text these policies had before this migration, same text the .apply.sql's drift guard pinned),
-- and restores find_duplicate_contacts to its pre-migration body: SECURITY INVOKER, STABLE,
-- SET search_path TO 'public', returning (source, id, name, mobile, email, created_at,
-- ticket_count, invoice_count) -- the exact live body this migration itself was reviewed against.
-- Deliberately does NOT remove the supabase_migrations.schema_migrations row -- a historical
-- record, not a toggle.

alter policy customers_select_own on public.customers
  using (id = current_customer_id());

alter policy customers_select_own_technician on public.customers
  using (
    exists (
      select 1
      from public.service_tickets t
      join public.appointments a on (a.ticket_id = t.id)
      where t.customer_id = customers.id
        and a.technician_id = current_technician_id()
    )
  );

alter policy customers_select_staff on public.customers
  using ((org_id = current_org_id()) and is_staff());

alter policy customers_update_own on public.customers
  using (id = current_customer_id());

alter policy customers_write_operation_admin on public.customers
  using ((org_id = current_org_id()) and ("current_role"() = 'operation_admin'::user_role))
  with check ((org_id = current_org_id()) and ("current_role"() = 'operation_admin'::user_role));

alter policy customers_write_sales on public.customers
  using ((org_id = current_org_id()) and is_sales_staff())
  with check ((org_id = current_org_id()) and is_sales_staff());

alter policy leads_insert_own_technician on public.leads
  with check ((owner_id = current_technician_id()) and (status = 'new'::lead_status));

alter policy leads_insert_sales on public.leads
  with check ((org_id = current_org_id()) and is_sales_staff());

alter policy leads_select_own_customer on public.leads
  using (customer_id = current_customer_id());

alter policy leads_select_own_technician on public.leads
  using (owner_id = current_technician_id());

alter policy leads_select_staff on public.leads
  using ((org_id = current_org_id()) and is_staff());

alter policy leads_update_sales on public.leads
  using ((org_id = current_org_id()) and is_sales_staff())
  with check ((org_id = current_org_id()) and is_sales_staff());

create or replace function public.find_duplicate_contacts(p_mobile text default null::text, p_email text default null::text)
returns table(source text, id uuid, name text, mobile text, email text, created_at timestamp with time zone, ticket_count bigint, invoice_count bigint)
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_org_id uuid := public.current_org_id();
  -- _mobile_key (20261016110000_test_customer_flag.sql, already live) -- last
  -- 10 digits only. Deliberately NOT the unapplied 2A migration's
  -- normalize_mobile (country-code/trunk-prefix aware): that function does not
  -- exist live yet, and this RPC must work independently of whether/when that
  -- other migration is ever approved.
  v_mobile_key text := public._mobile_key(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.is_staff() then
    raise exception 'find_duplicate_contacts: caller is not staff';
  end if;

  if v_org_id is null then
    raise exception 'find_duplicate_contacts: no organisation for the current session';
  end if;

  -- Nothing to match on -- return no rows rather than scanning the org.
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
    -- Leads have no email column -- mobile-only match. Always zero
    -- ticket/invoice counts (a lead isn't a customer yet).
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
grant execute on function public.find_duplicate_contacts(text, text) to authenticated, service_role;
