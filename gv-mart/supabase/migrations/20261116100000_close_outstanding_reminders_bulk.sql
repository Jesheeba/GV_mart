-- Accounts follow-up, reminder management batch, item 2 — auto-close ALL
-- open customer-outstanding reminders whose customer's balance has reached
-- zero, computed on read (owner's condition: no trigger, no background job)
-- whenever the Customer Outstanding list or the new Reminders view loads,
-- not only when one customer's own "Follow up" dialog opens.
--
-- This is the same logic close_outstanding_reminders_if_zero (20261115100300)
-- already runs for a single customer, generalised into a loop over every
-- customer in this org that currently has an open reminder. No money table
-- is touched or written to -- only customer_outstanding_reminders rows are
-- updated, exactly as the existing per-customer version does.

create or replace function public.close_outstanding_reminders_if_zero_bulk()
returns int
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_org_id();
  v_total_closed int := 0;
  v_customer record;
  v_outstanding numeric;
  v_closed int;
begin
  if v_org is null or not coalesce(public.is_master(), false) then
    raise exception 'close_outstanding_reminders_if_zero_bulk: master only';
  end if;

  for v_customer in
    select distinct customer_id
    from public.customer_outstanding_reminders
    where org_id = v_org and status = 'open'
  loop
    select coalesce(sum(i.total - i.amount_paid), 0) into v_outstanding
    from public.invoices i
    where i.org_id = v_org
      and i.customer_id = v_customer.customer_id
      and i.payment_status <> 'paid'
      and i.total - i.amount_paid > 0;

    if v_outstanding <= 0 then
      with closed as (
        update public.customer_outstanding_reminders
          set status = 'done', source = 'system', closed_by = null, closed_at = now(),
              close_reason = 'outstanding reached zero'
          where org_id = v_org and customer_id = v_customer.customer_id and status = 'open'
          returning 1
      )
      select count(*) into v_closed from closed;
      v_total_closed := v_total_closed + v_closed;
    end if;
  end loop;

  return v_total_closed;
end;
$function$;
revoke all on function public.close_outstanding_reminders_if_zero_bulk() from public, anon;
grant execute on function public.close_outstanding_reminders_if_zero_bulk() to authenticated;
