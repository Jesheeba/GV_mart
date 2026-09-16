-- Lead/Quotation enhancement spec (2026-09-16), Item 1: marking a lead
-- "lost" must carry a reason, server-enforced — same discipline as
-- cancel_service_ticket's required cancellation_reason (20260724090000),
-- not the weaker client-only quotations.lost_reason pattern next to it.

alter table public.leads add column lost_reason text;

-- Old 2-arg signature must be dropped, not just replaced — adding a
-- parameter changes the function's identity, so `create or replace` would
-- otherwise leave both overloads in place and every 2-arg call from
-- supabase-js (nothing passes p_reason on non-lost transitions) becomes
-- ambiguous between them.
drop function if exists public.update_lead_status(uuid, public.lead_status);

create or replace function public.update_lead_status(p_lead_id uuid, p_status public.lead_status, p_reason text default null)
returns void
language plpgsql
security invoker
as $$
begin
  if not public.is_sales_staff() then
    raise exception 'update_lead_status: caller is not sales staff';
  end if;
  if p_status = 'lost' and trim(coalesce(p_reason, '')) = '' then
    raise exception 'update_lead_status: a reason is required to mark a lead lost';
  end if;

  update public.leads
    set status = p_status,
        lost_reason = case when p_status = 'lost' then p_reason else null end
    where id = p_lead_id and org_id = public.current_org_id();
  if not found then
    raise exception 'update_lead_status: lead % not found', p_lead_id;
  end if;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (public.current_org_id(), p_lead_id, 'status_change', case when p_status = 'lost' then p_reason else p_status::text end);
end;
$$;

grant execute on function public.update_lead_status(uuid, public.lead_status, text) to authenticated;
