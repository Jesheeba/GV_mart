-- A customer entered by mistake as a lead can be (a) moved to Customers and
-- removed from Leads in one step, or (b) simply deleted. leads has no DELETE
-- RLS policy, so both go through SECURITY DEFINER RPCs with explicit role and
-- org checks. Each leaves one audit_log row (leads is not trigger-audited —
-- that would log every lead edit, not just removals).
--
-- Child rows: lead_activities / lead_items cascade; quotations.lead_id and
-- service_tickets.lead_id are ON DELETE SET NULL, so quotes and tickets that
-- came from the lead survive, just unlinked from it.

create or replace function public.delete_lead(p_lead_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead public.leads;
begin
  if not public.is_master() then
    raise exception 'delete_lead: only the master can delete a lead';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and org_id = public.current_org_id();
  if not found then
    raise exception 'delete_lead: lead % not found', p_lead_id;
  end if;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_lead.org_id, auth.uid(), 'DELETE', 'leads', v_lead.id, to_jsonb(v_lead), null);

  delete from public.leads where id = v_lead.id;
end;
$$;

create or replace function public.move_lead_to_customer(p_lead_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid := public.current_org_id();
  v_lead public.leads;
  v_customer_id uuid;
begin
  if not public.is_sales_staff() then
    raise exception 'move_lead_to_customer: caller is not sales staff';
  end if;

  select * into v_lead from public.leads where id = p_lead_id and org_id = v_org_id;
  if not found then
    raise exception 'move_lead_to_customer: lead % not found', p_lead_id;
  end if;

  v_customer_id := v_lead.customer_id;

  if v_customer_id is null then
    if v_lead.mobile is null or trim(v_lead.mobile) = '' then
      raise exception 'move_lead_to_customer: this lead has no mobile number, so a customer cannot be created from it';
    end if;
    -- Same dedupe rule as update_lead_status: reuse a customer with this mobile.
    select id into v_customer_id from public.customers where org_id = v_org_id and mobile = v_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (v_org_id, v_lead.name, v_lead.mobile, v_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  -- Quotes raised against the lead keep working: attach them to the customer.
  update public.quotations set customer_id = v_customer_id
    where lead_id = v_lead.id and customer_id is null;

  insert into public.audit_log (org_id, actor_id, action, table_name, row_id, before, after)
  values (v_org_id, auth.uid(), 'DELETE', 'leads', v_lead.id, to_jsonb(v_lead),
          jsonb_build_object('moved_to_customer_id', v_customer_id));

  delete from public.leads where id = v_lead.id;

  return v_customer_id;
end;
$$;

-- This project auto-grants EXECUTE to anon on new functions; lock both down.
revoke all on function public.delete_lead(uuid) from public, anon;
revoke all on function public.move_lead_to_customer(uuid) from public, anon;
grant execute on function public.delete_lead(uuid) to authenticated;
grant execute on function public.move_lead_to_customer(uuid) to authenticated;
