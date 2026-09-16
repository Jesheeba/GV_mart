-- Lead/Quotation enhancement spec (2026-09-16), Item 3: a lead won with no
-- linked customer gets one auto-created (matched by mobile to an existing
-- customer instead of duplicating, when one already exists in the org) and
-- flagged needs_setup so staff know its address/family details are
-- incomplete. Approved scope: auto-create ONLY when leads.customer_id is
-- currently null; already-linked leads are left untouched.

alter table public.customers add column needs_setup boolean not null default false;

drop function if exists public.update_lead_status(uuid, public.lead_status, text);

create or replace function public.update_lead_status(p_lead_id uuid, p_status public.lead_status, p_reason text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_lead public.leads;
  v_customer_id uuid;
begin
  if not public.is_sales_staff() then
    raise exception 'update_lead_status: caller is not sales staff';
  end if;
  if p_status = 'lost' and trim(coalesce(p_reason, '')) = '' then
    raise exception 'update_lead_status: a reason is required to mark a lead lost';
  end if;

  v_org_id := public.current_org_id();

  select * into v_lead from public.leads where id = p_lead_id and org_id = v_org_id;
  if not found then
    raise exception 'update_lead_status: lead % not found', p_lead_id;
  end if;

  if p_status = 'won' and v_lead.customer_id is null and v_lead.mobile is not null then
    select id into v_customer_id from public.customers where org_id = v_org_id and mobile = v_lead.mobile limit 1;
    if v_customer_id is null then
      insert into public.customers (org_id, name, mobile, source, needs_setup)
      values (v_org_id, v_lead.name, v_lead.mobile, v_lead.source, true)
      returning id into v_customer_id;
    end if;
  end if;

  update public.leads
    set status = p_status,
        lost_reason = case when p_status = 'lost' then p_reason else null end,
        customer_id = coalesce(v_customer_id, customer_id)
    where id = p_lead_id;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (v_org_id, p_lead_id, 'status_change', case when p_status = 'lost' then p_reason else p_status::text end);
end;
$$;

grant execute on function public.update_lead_status(uuid, public.lead_status, text) to authenticated;
