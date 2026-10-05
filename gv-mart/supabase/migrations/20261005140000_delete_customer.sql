-- Hard-deleting a customer. customers has no DELETE RLS policy, so this goes
-- through a SECURITY DEFINER RPC. The caller must be the master AND pass the
-- customer's exact name — enforced here, not just in the UI, so the typed
-- confirmation can't be skipped by calling the RPC directly.
--
-- What a delete takes with it (FK rules): addresses, family members, AMC
-- contracts, warranties, rental contracts, quotations, referral points,
-- payment proofs, exemption windows and — via service_tickets — every ticket
-- with its appointments/visits/photos cascade. Call logs, leads and WhatsApp
-- rows are kept, just unlinked. Invoices are RESTRICT: a customer with any
-- invoice cannot be deleted (financial records must survive), and a customer
-- with an app login is refused because the login would be left orphaned.

create or replace function public.customer_delete_impact(p_customer_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'tickets',          (select count(*) from service_tickets where customer_id = p_customer_id),
    'amc_contracts',    (select count(*) from amc_contracts where customer_id = p_customer_id),
    'warranties',       (select count(*) from warranties where customer_id = p_customer_id),
    'rental_contracts', (select count(*) from rental_contracts where customer_id = p_customer_id),
    'quotations',       (select count(*) from quotations where customer_id = p_customer_id),
    'addresses',        (select count(*) from addresses where customer_id = p_customer_id),
    'members',          (select count(*) from customer_members where customer_id = p_customer_id),
    'invoices',         (select count(*) from invoices where customer_id = p_customer_id),
    'has_login',        (select primary_profile_id is not null from customers where id = p_customer_id)
  )
$$;

create or replace function public.delete_customer(p_customer_id uuid, p_confirm_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer public.customers;
  v_impact jsonb;
begin
  if not public.is_master() then
    raise exception 'delete_customer: only the master can delete a customer';
  end if;

  select * into v_customer from public.customers where id = p_customer_id and org_id = public.current_org_id();
  if not found then
    raise exception 'delete_customer: customer % not found', p_customer_id;
  end if;

  if trim(coalesce(p_confirm_name, '')) <> trim(v_customer.name) then
    raise exception 'delete_customer: the typed name does not match the customer name';
  end if;

  if v_customer.primary_profile_id is not null then
    raise exception 'delete_customer: this customer has an app login and cannot be deleted';
  end if;

  v_impact := public.customer_delete_impact(p_customer_id);
  if (v_impact->>'invoices')::int > 0 then
    raise exception 'delete_customer: this customer has % invoice(s); invoices are financial records and must be kept', v_impact->>'invoices';
  end if;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_customer.org_id, auth.uid(), 'DELETE', 'customers', v_customer.id, to_jsonb(v_customer), v_impact);

  delete from public.customers where id = v_customer.id;
end;
$$;

revoke all on function public.customer_delete_impact(uuid) from public, anon;
revoke all on function public.delete_customer(uuid, text) from public, anon;
grant execute on function public.customer_delete_impact(uuid) to authenticated;
grant execute on function public.delete_customer(uuid, text) to authenticated;
