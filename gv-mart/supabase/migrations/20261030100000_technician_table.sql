-- Technician table (batch-17 item 15, owner definitions 2026-10-15). Design: gv-mart/docs/design-technician-table.md
--
--   org_holidays                    master-kept list of holidays ("minus holidays if any"; empty = none).
--   invoices.referred_by_technician_id  who brought the customer, stamped at invoice creation, FORWARD-ONLY.
--   _trg_invoice_stamp_referral     BEFORE INSERT on invoices: sets that column from the customer's technician-referral lead.
--   report_technician_table(from,to)  one row per technician for a date range (ops staff, read-only).
--
-- Definitions (owner):
--   revenue       = the invoice totals (invoices.total) of COMPLETED jobs. A completed ticket's invoice is credited to the technician
--                   of the ticket's last finished visit, in the period of that visit's end (IST). Not service_charge, not collected.
--   working days  = Monday to Saturday between the period start and min(period end, today IST), minus org_holidays, counted from
--                   the day the technician record was created.
--   absent days   = working days minus the working days the technician was present (an attendance check-in) or on leave
--                   (technician_availability status 'leave'). A day that is both present and leave counts once.
--   Google reviews: NOT in this table (no per-technician Google review column anywhere).
--   referral revenue: invoice totals stamped to the technician, split service (the invoice belongs to a service ticket), AMC
--                   (type amc) and sales (everything else). FORWARD-ONLY: only invoices created after this migration are stamped;
--                   nothing existing is back-filled.
--
-- Referral stamping rule (a decision for the owner; one line to change): the customer has a lead with source 'referral' or 'field'
-- (technician-originated), owner_id = a technician of this organisation, status not lost, not a test lead, created within the last
-- 30 days (the same window the app uses to merge an enquiry into an open lead). The most recent such lead wins. A walk-in sale
-- with a referring technician mints exactly such a lead in the same transaction, so it is stamped on the spot. The trigger never
-- blocks an invoice: any error leaves the column NULL.
--
-- Rollback: supabase/rollbacks/20261030100000_technician_table.rollback.sql

-- 1. holidays -------------------------------------------------------------------------------------------------------
create table public.org_holidays (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  holiday_date date not null,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique (org_id, holiday_date)
);
alter table public.org_holidays enable row level security;
create policy org_holidays_select_staff on public.org_holidays for select
  using (org_id = public.current_org_id() and public.is_staff());
create policy org_holidays_write_master on public.org_holidays for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_org_holidays after insert or update or delete on public.org_holidays
  for each row execute function public.audit_master_change();
revoke all on public.org_holidays from public, anon, authenticated;
grant select, insert, update, delete on public.org_holidays to authenticated, service_role;

-- 2. referral stamp on invoices (forward-only) ------------------------------------------------------------------------
alter table public.invoices add column referred_by_technician_id uuid references public.technicians (id) on delete set null;
create index invoices_referred_by_idx on public.invoices (org_id, referred_by_technician_id, created_at)
  where referred_by_technician_id is not null;

create function public._trg_invoice_stamp_referral()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tech uuid;
begin
  if new.referred_by_technician_id is not null or new.customer_id is null then
    return new;
  end if;
  begin
    select l.owner_id into v_tech
      from public.leads l
      join public.technicians t on t.id = l.owner_id and t.org_id = new.org_id
     where l.org_id = new.org_id and l.customer_id = new.customer_id
       and l.source in ('referral', 'field') and l.owner_id is not null
       and l.status::text <> 'lost' and not coalesce(l.is_test, false)
       and l.created_at <= now() and l.created_at > now() - interval '30 days'
     order by l.created_at desc
     limit 1;
    new.referred_by_technician_id := v_tech;
  exception when others then
    new.referred_by_technician_id := null;          -- an invoice is never blocked by attribution
  end;
  return new;
end;
$$;
revoke all on function public._trg_invoice_stamp_referral() from public, anon, authenticated;
create trigger invoices_stamp_referral before insert on public.invoices
  for each row execute function public._trg_invoice_stamp_referral();

-- 3. the table ---------------------------------------------------------------------------------------------------------
create function public.report_technician_table(p_from date, p_to date)
returns table (
  technician_id uuid, name text, is_active boolean,
  jobs_completed integer, jobs_invoiced integer, revenue numeric, avg_call_value numeric,
  avg_rating numeric, rating_count integer,
  working_days integer, holidays integer, present_days integer, leave_days integer, absent_days integer,
  referral_service numeric, referral_sales numeric, referral_amc numeric, referral_total numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_org   uuid := public.current_org_id();
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_end   date;
begin
  if not public.is_ops_staff() then
    raise exception 'not permitted: only master or operations can view the technician table';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid date range';
  end if;
  if p_to - p_from > 366 then
    raise exception 'the date range is limited to 366 days';
  end if;
  v_end := least(p_to, v_today);

  return query
  with techs as (
    select t.id, coalesce(pr.full_name, '—') as nm, t.is_active,
           greatest(p_from, (t.created_at at time zone 'Asia/Kolkata')::date) as d_from
      from public.technicians t
      left join public.profiles pr on pr.id = t.profile_id
     where t.org_id = v_org
  ),
  days as (        -- Monday to Saturday, from the technician's start, up to today
    select t.id as tech_id, g::date as d
      from techs t
      cross join lateral generate_series(t.d_from::timestamp, v_end::timestamp, interval '1 day') g
     where extract(isodow from g) between 1 and 6
  ),
  hol as (select h.holiday_date from public.org_holidays h where h.org_id = v_org),
  wd as (select d.tech_id, d.d from days d where d.d not in (select holiday_date from hol)),
  pres as (
    select a.technician_id as tech_id, a.date as d
      from public.attendance a
     where a.org_id = v_org and a.check_in_at is not null and a.date between p_from and v_end
     group by 1, 2
  ),
  lv as (
    select ta.technician_id as tech_id, ta.date as d
      from public.technician_availability ta
     where ta.org_id = v_org and ta.status = 'leave' and ta.date between p_from and v_end
  ),
  att as (
    select w.tech_id,
           count(*) as working,
           count(*) filter (where exists (select 1 from pres p where p.tech_id = w.tech_id and p.d = w.d)) as present_w,
           count(*) filter (where exists (select 1 from lv l where l.tech_id = w.tech_id and l.d = w.d)) as leave_w,
           count(*) filter (where exists (select 1 from pres p where p.tech_id = w.tech_id and p.d = w.d)
                               or exists (select 1 from lv l where l.tech_id = w.tech_id and l.d = w.d)) as covered
      from wd w
     group by w.tech_id
  ),
  hol_n as (
    select d.tech_id, count(*) as n from days d where d.d in (select holiday_date from hol) group by d.tech_id
  ),
  last_visit as (   -- one row per completed ticket: the technician of its last finished visit
    select distinct on (st.id) st.id as ticket_id, st.invoice_id, st.customer_id, sv.technician_id, sv.timer_end, sv.id as visit_id
      from public.service_tickets st
      join public.service_visits sv on sv.ticket_id = st.id and sv.timer_end is not null
     where st.org_id = v_org and st.status = 'completed'
     order by st.id, sv.timer_end desc
  ),
  jobs as (
    select lv2.technician_id as tech_id,
           count(*) as jobs,
           count(i.id) as invoiced,
           coalesce(sum(i.total), 0) as revenue
      from last_visit lv2
      left join public.invoices i on i.id = lv2.invoice_id and i.org_id = v_org
     where (lv2.timer_end at time zone 'Asia/Kolkata')::date between p_from and p_to
       and not public.is_test_customer(lv2.customer_id)
     group by lv2.technician_id
  ),
  rat as (
    select lv2.technician_id as tech_id, avg(r.stars) as avg_stars, count(*) as cnt
      from last_visit lv2
      join public.ratings r on r.visit_id = lv2.visit_id and r.org_id = v_org
     where (lv2.timer_end at time zone 'Asia/Kolkata')::date between p_from and p_to
       and not public.is_test_customer(lv2.customer_id)
     group by lv2.technician_id
  ),
  ref as (
    select i.referred_by_technician_id as tech_id,
           sum(i.total) filter (where exists (select 1 from public.service_tickets st where st.invoice_id = i.id)) as svc,
           sum(i.total) filter (where i.type::text = 'amc' and not exists (select 1 from public.service_tickets st where st.invoice_id = i.id)) as amc,
           sum(i.total) filter (where i.type::text <> 'amc' and not exists (select 1 from public.service_tickets st where st.invoice_id = i.id)) as sales
      from public.invoices i
     where i.org_id = v_org and i.referred_by_technician_id is not null
       and (i.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
       and not public.is_test_customer(i.customer_id)
     group by i.referred_by_technician_id
  )
  select t.id, t.nm, t.is_active,
         coalesce(j.jobs, 0)::integer,
         coalesce(j.invoiced, 0)::integer,
         coalesce(j.revenue, 0)::numeric,
         case when coalesce(j.invoiced, 0) > 0 then round(j.revenue / j.invoiced, 2) end,
         case when coalesce(r.cnt, 0) > 0 then round(r.avg_stars, 2) end,
         coalesce(r.cnt, 0)::integer,
         coalesce(a.working, 0)::integer,
         coalesce(h.n, 0)::integer,
         coalesce(a.present_w, 0)::integer,
         coalesce(a.leave_w, 0)::integer,
         (coalesce(a.working, 0) - coalesce(a.covered, 0))::integer,
         coalesce(f.svc, 0)::numeric,
         coalesce(f.sales, 0)::numeric,
         coalesce(f.amc, 0)::numeric,
         (coalesce(f.svc, 0) + coalesce(f.sales, 0) + coalesce(f.amc, 0))::numeric
    from techs t
    left join att a on a.tech_id = t.id
    left join hol_n h on h.tech_id = t.id
    left join jobs j on j.tech_id = t.id
    left join rat r on r.tech_id = t.id
    left join ref f on f.tech_id = t.id
   order by coalesce(j.revenue, 0) desc, t.nm, t.id;
end;
$$;
revoke all on function public.report_technician_table(date, date) from public, anon, authenticated;
grant execute on function public.report_technician_table(date, date) to authenticated, service_role;

notify pgrst, 'reload schema';
