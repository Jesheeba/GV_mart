-- Referral transparency, phase 1 (2026-10-16) - batch-2 item 4, READ-ONLY (no existing table or function is changed).
-- Design: docs/plan-referral.md. Decisions recorded 2026-10-16: per-referral master-set bonus (phase 3), on-site AMC counts when it
-- came through a referral lead, three states pending/approved/paid (phase 3), earned at ticket completion, ONE referral per
-- customer per technician (later purchases are events and earn no second bonus), invoices carry the referral link (phase 2).
--
--   * v_referral_events : one row per referral lead x linked ticket (security_invoker, so the caller's RLS applies).
--   * referral_overview(p_technician_id) : one record per (customer, referring technician): who referred whom, the origin
--     (sale / AMC / service), every later ticket as an event, the first completed ticket (the one that earns the bonus), and the
--     bonus block. Bonus amount/state are 'not_configured' until phase 3 adds the master-set per-referral amount - nothing is
--     invented here. Flagged test customers are excluded.
-- Access: master / operation_admin / sales_admin see the whole organisation (optionally one technician); a technician sees only
-- their own referrals; everyone else is refused.

create view public.v_referral_events with (security_invoker = on) as
select
  l.org_id,
  l.id as lead_id,
  l.owner_id as referrer_technician_id,
  l.customer_id,
  l.created_at as referred_at,
  l.status as lead_status,
  t.id as ticket_id,
  t.type::text as ticket_type,
  t.status::text as ticket_status,
  t.invoice_id,
  t.contract_id,
  t.created_at as ticket_created_at,
  case when t.status::text = 'completed'
       then (select max(v.timer_end) from public.service_visits v where v.ticket_id = t.id and v.timer_end is not null)
  end as completed_at
from public.leads l
left join public.service_tickets t on t.lead_id = l.id
where l.source = 'referral' and l.customer_id is not null and l.owner_id is not null and not l.is_test;

revoke all on public.v_referral_events from public, anon;
grant select on public.v_referral_events to authenticated, service_role;

create function public.referral_overview(p_technician_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org uuid := public.current_org_id();
  v_tech uuid := public.current_technician_id();
  v_staff boolean := public.is_staff();
  v_filter uuid;
  v_result jsonb;
begin
  if v_org is null or not (v_staff or v_tech is not null) then
    raise exception 'referral_overview: not allowed';
  end if;
  -- a technician only ever sees their own referrals, whatever they ask for
  v_filter := case when v_staff then p_technician_id else v_tech end;

  with ev as (
    select e.*
    from public.v_referral_events e
    where e.org_id = v_org
      and (v_filter is null or e.referrer_technician_id = v_filter)
      and not public.is_test_customer(e.customer_id)
  ),
  grp as (
    select
      ev.org_id, ev.referrer_technician_id, ev.customer_id,
      min(ev.referred_at) as referred_at,
      (array_agg(ev.lead_id order by ev.referred_at, ev.lead_id))[1] as referral_lead_id,
      count(distinct ev.lead_id) as lead_count
    from ev
    group by ev.org_id, ev.referrer_technician_id, ev.customer_id
  ),
  first_done as (
    select distinct on (ev.referrer_technician_id, ev.customer_id)
      ev.referrer_technician_id, ev.customer_id, ev.ticket_id, ev.completed_at
    from ev
    where ev.completed_at is not null
    order by ev.referrer_technician_id, ev.customer_id, ev.completed_at, ev.ticket_id
  ),
  origin as (
    select g.referral_lead_id,
      (select a.note from public.lead_activities a
        where a.type = 'converted'
          and a.lead_id in (select e2.lead_id from ev e2 where e2.referrer_technician_id = g.referrer_technician_id and e2.customer_id = g.customer_id)
        order by a.at, a.id limit 1) as note
    from grp g
  )
  select jsonb_build_object(
    'summary', jsonb_build_object(
      'referrals', (select count(*) from grp),
      'with_tickets', (select count(*) from grp g where exists (select 1 from ev where ev.referrer_technician_id = g.referrer_technician_id and ev.customer_id = g.customer_id and ev.ticket_id is not null)),
      'completed', (select count(*) from first_done)
    ),
    'referrals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'referral_id', g.referral_lead_id,
        'referrer_technician_id', g.referrer_technician_id,
        'referrer_name', (select p.full_name from public.technicians t join public.profiles p on p.id = t.profile_id where t.id = g.referrer_technician_id),
        'customer_id', g.customer_id,
        'customer_name', (select c.name from public.customers c where c.id = g.customer_id),
        'referred_at', g.referred_at,
        'lead_count', g.lead_count,
        'origin_note', (select o.note from origin o where o.referral_lead_id = g.referral_lead_id),
        'status', case
            when fd.ticket_id is not null then 'completed'
            when exists (select 1 from ev where ev.referrer_technician_id = g.referrer_technician_id and ev.customer_id = g.customer_id and ev.ticket_id is not null) then 'in_progress'
            else 'referred' end,
        'first_completed_ticket_id', fd.ticket_id,
        'first_completed_at', fd.completed_at,
        'bonus', jsonb_build_object(
            'state', 'not_configured',
            'amount', null,
            'earned_at', fd.completed_at,
            'note', 'Per-referral bonus amount and pending/approved/paid states arrive with phase 3'),
        'events', coalesce((
          select jsonb_agg(jsonb_build_object(
              'ticket_id', ev.ticket_id,
              'ticket_type', ev.ticket_type,
              'ticket_status', ev.ticket_status,
              'created_at', ev.ticket_created_at,
              'completed_at', ev.completed_at,
              'invoice_id', ev.invoice_id,
              'contract_id', ev.contract_id,
              'earns_bonus', (ev.ticket_id = fd.ticket_id)
            ) order by ev.ticket_created_at, ev.ticket_id)
          from ev
          where ev.referrer_technician_id = g.referrer_technician_id and ev.customer_id = g.customer_id and ev.ticket_id is not null
        ), '[]'::jsonb)
      ) order by g.referred_at desc)
      from grp g
      left join first_done fd on fd.referrer_technician_id = g.referrer_technician_id and fd.customer_id = g.customer_id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.referral_overview(uuid) from public, anon;
grant execute on function public.referral_overview(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
