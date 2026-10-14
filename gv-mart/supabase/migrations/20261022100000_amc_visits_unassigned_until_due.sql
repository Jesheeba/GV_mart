-- AMC visit schedule rule, and who gets a visit assigned when (owner decisions 2026-10-13, revised 2026-10-14).
--
-- BEFORE: every AMC generator (sell_amc_plan, sell_amc_plan_onsite, renew_amc_plan, the AMC add-on in create_sale) called the
-- assignment engine for EVERY visit at purchase time. With the date-aware busy test every future date looks free, attendance is
-- skipped for future dates, and the tie-break is "oldest technician", so one technician got all six visits of a 3-year plan,
-- months or years ahead, without leave, attendance or capacity ever being looked at (test contract e13bcc7c, 13 Oct 2026).
-- The same generators also put visit 1 at start + gap and the last visit ON the expiry day (13 Apr 2027 ... 13 Oct 2029).
--
-- AFTER:
--   1. SCHEDULE RULE. visits = visits per year x plan years; gap = 12 months / visits per year; visit 1 is on the plan START date
--      and visit k on start + (k - 1) x gap, so the last visit falls one gap before expiry. Plan values come from the Masters plan.
--      Every date is then rolled forward to a working day (settings.lead_work_days) exactly as before. A visit that would be
--      dated before today (back-dated sale) is not created (its visit number is kept); a visit dated today starts at the next
--      quarter hour, or on the next working day if the shop is already closed.
--   2. one shared helper, _schedule_amc_visits(), creates the visit tickets + appointments (visit_no unique per contract). The
--      four generators call it; their bodies are otherwise the live bodies.
--   3. ASSIGNMENT. A visit dated within settings.amc_assign_window_days (default 7) of today, including one dated today, is
--      assigned AT SALE by the same engine (_auto_assign_ticket_internal): attendance for today, leave, capacity, busy time and
--      location are respected. If nobody is free or checked in, the engine's normal "needs manual assignment" alert fires
--      (operation_admin). Visits beyond the window stay open and unassigned, with no SLA, and wait for the daily job.
--   4. assign_due_amc_visits(p_now) is that daily job: it assigns every open unassigned contract visit whose date is within the
--      window, one ticket at a time, each isolated so one failure never stops the rest. Repeat "needs manual assignment" alerts
--      for the same ticket are collapsed to the oldest unread one.
--   5. it runs from pg_cron daily at 06:30 IST (01:00 UTC), pure SQL, no HTTP, independent of the GitHub schedules; a heartbeat
--      row (cron_job_heartbeats.job_key = 'amc_assign_due_visits') and a 08:30 IST dead-man check raise a master notification
--      if it has not run in 26 hours.
--   6. an AFTER UPDATE OF scheduled_at trigger re-checks a single visit when it is rescheduled.
--   7. _ticket_is_future_amc_visit() is the one definition of "not yet due": visits beyond the window are excluded from the
--      report_kpi_tiles open_tickets tile here and from the Unassigned / Pending counts in the app (src/lib/ticketFilters.ts).
--   8. legacy milestone 'booked' (INSERT trigger gets a WHEN contract_id is null; the function is not re-issued) and the
--      automation ticket.created emit are skipped for contract visit tickets.
--   9. amc_contracts.next_service_date is set to the date of the first visit that was created.
--  10. BACK-DATED SALES (owner decision 2026-10-14). A sale whose start date is more than settings.amc_backdate_max_days (default 7)
--      in the past is REFUSED unless a master passes p_confirm_backdated = true (sell_amc_plan only: it is the only generator that
--      takes a start date from the user). Inside the threshold, visits dated before today are still not created, but this is now
--      recorded and shown: amc_contracts.visits_skipped (the skipped visit numbers), a master notification at sale, and the
--      skipped visits named in the sale response. A gap in visit_no alone is not a record. The term is NOT shifted.
--      visits_skipped holds the plan's visit numbers exactly as they would have been stored (v_base + i). The response's
--      would_have_been_on is the UNROLLED date, public._amc_visit_date(start, visits per year, k), i.e. BEFORE the weekend /
--      non-working-day roll-forward, so for a skipped visit it can name a day the shop is closed.
-- Nothing is deleted. The existing contract's visits are untouched (they are assigned today; cancelling that contract is a
-- separate, supported action).

-- ── setting ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
alter table public.settings
  add column if not exists amc_assign_window_days integer not null default 7;
alter table public.settings drop constraint if exists settings_amc_assign_window_check;
alter table public.settings add constraint settings_amc_assign_window_check check (amc_assign_window_days between 1 and 90);

alter table public.settings
  add column if not exists amc_backdate_max_days integer not null default 7;
alter table public.settings drop constraint if exists settings_amc_backdate_max_check;
alter table public.settings add constraint settings_amc_backdate_max_check check (amc_backdate_max_days between 0 and 90);

-- the record of a back-dated sale: which visit numbers were not created, and the master who confirmed a start beyond the threshold
alter table public.amc_contracts add column if not exists visits_skipped integer[] not null default '{}';
alter table public.amc_contracts add column if not exists backdated_confirmed_by uuid references public.profiles(id) on delete set null;

-- ── visit_no, unique per contract ───────────────────────────────────────────────────────────────────────────────────────
alter table public.service_tickets add column if not exists visit_no integer;

-- one-off backfill in schedule order; triggers off for this statement only so it does not bump updated_at or write audit rows
set local session_replication_role = replica;
update public.service_tickets t
   set visit_no = x.rn
  from (
    select s.id,
           row_number() over (
             partition by s.contract_id
             order by (select min(a.scheduled_at) from public.appointments a where a.ticket_id = s.id), s.created_at, s.id) as rn
      from public.service_tickets s
     where s.contract_id is not null
  ) x
 where x.id = t.id and t.visit_no is null;
set local session_replication_role = origin;

create unique index if not exists service_tickets_contract_visit_no_uniq
  on public.service_tickets (contract_id, visit_no)
  where contract_id is not null and visit_no is not null;

-- ── "not yet due": the one definition ──────────────────────────────────────────────────────────────────────────────────
create or replace function public._ticket_is_future_amc_visit(p_ticket_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.service_tickets t
      join public.appointments a on a.ticket_id = t.id
      join public.settings s on s.org_id = t.org_id
     where t.id = p_ticket_id
       and t.contract_id is not null
       and t.type = 'amc'
       and t.status = 'open'
       and a.status = 'scheduled'
       and a.technician_id is null
       and a.scheduled_at is not null
       and (a.scheduled_at at time zone 'Asia/Kolkata')::date
             > (now() at time zone 'Asia/Kolkata')::date + s.amc_assign_window_days
       and not exists (
             select 1 from public.appointments a2
              where a2.ticket_id = t.id and a2.technician_id is not null and a2.status in ('scheduled', 'in_progress'))
  )
$$;
revoke all on function public._ticket_is_future_amc_visit(uuid) from public, anon, authenticated;
grant execute on function public._ticket_is_future_amc_visit(uuid) to service_role;

-- ── visit date: start + (k - 1) x (12 months / visits per year) ────────────────────────────────────────────────────────
-- Whole months are added to the START date (never cumulatively, so a 31 January start does not drift), and the fractional
-- part of the gap is added as days at 30.4375 days a month. Plans of 1, 2, 3, 4, 6 or 12 visits a year have no fractional part.
create or replace function public._amc_visit_date(p_start date, p_visits_per_year integer, p_k integer)
returns date
language sql
immutable
set search_path = public
as $$
  select ((p_start + make_interval(months => b.m))::date + b.d)
    from (
      select floor(a.x)::integer as m, round((a.x - floor(a.x)) * 30.4375)::integer as d
        from (select 12.0 * (p_k - 1) / greatest(coalesce(p_visits_per_year, 1), 1) as x) a
    ) b
$$;
revoke all on function public._amc_visit_date(date, integer, integer) from public, anon, authenticated;
grant execute on function public._amc_visit_date(date, integer, integer) to service_role;

-- ── the shared helper: visit tickets + appointments, assigned at sale when inside the window ───────────────────────────────
-- Returns the new ticket ids in visit order. p_now exists so tests can fix the clock; callers never pass it.
create or replace function public._schedule_amc_visits(
  p_org_id          uuid,
  p_customer_id     uuid,
  p_contract_id     uuid,
  p_product_id      uuid,
  p_plan_name       text,
  p_visits_per_year integer,
  p_total_visits    integer,
  p_start_date      date,
  p_expiry          date,
  p_address_id      uuid,
  p_lead_id         uuid,
  p_channel         text,
  p_now             timestamptz default now()
)
returns uuid[]
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids      uuid[] := '{}';
  v_ticket   uuid;
  v_date     date;
  v_ts       timestamptz;
  v_local    timestamp;
  v_base     integer;
  v_today    date := (p_now at time zone 'Asia/Kolkata')::date;
  v_window   integer;
  v_work_end time;
  v_first    date;
  v_skipped  integer[] := '{}';
  i          integer;
begin
  select s.amc_assign_window_days, s.work_end into v_window, v_work_end from public.settings s where s.org_id = p_org_id;
  v_window   := coalesce(v_window, 7);
  v_work_end := coalesce(v_work_end, time '17:30');

  select coalesce(max(t.visit_no), 0) into v_base from public.service_tickets t where t.contract_id = p_contract_id;

  for i in 1..coalesce(p_total_visits, 0) loop
    -- visit 1 is the start date; visit k is start + (k - 1) x gap
    v_date := public._amc_visit_date(p_start_date, p_visits_per_year, i);
    exit when v_date > p_expiry;
    v_date := public._visit_working_day(p_org_id, v_date);

    -- a visit that would already be in the past cannot be serviced: its number is kept, no ticket is made
    if v_date < v_today then
      v_skipped := array_append(v_skipped, v_base + i);
      continue;
    end if;

    v_ts := public._visit_start_ts(p_org_id, v_date);
    if v_date = v_today and v_ts <= p_now then
      if (p_now at time zone 'Asia/Kolkata')::time >= v_work_end then
        -- sold after closing time: the visit moves to the next working day
        v_date := public.lead_next_working_day(p_org_id, v_today);
        v_ts   := public._visit_start_ts(p_org_id, v_date);
      else
        -- sold during the working day: the visit starts at the next quarter hour, never in the past
        v_local := p_now at time zone 'Asia/Kolkata';
        v_ts := least(
                  (date_trunc('hour', v_local) + ceil(extract(epoch from (v_local - date_trunc('hour', v_local))) / 900.0) * interval '15 minutes') at time zone 'Asia/Kolkata',
                  (v_today + v_work_end) at time zone 'Asia/Kolkata');
      end if;
    end if;

    insert into public.service_tickets (
      org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
      type, priority, status, channel, contract_id, lead_id, visit_no
    ) values (
      p_org_id, p_customer_id, p_address_id, p_product_id,
      format('AMC scheduled service %s of %s', i, p_total_visits), p_plan_name,
      'amc', 'normal', 'open', p_channel::public.ticket_channel, p_contract_id, p_lead_id, v_base + i   -- FINDER CREDIT
    )
    returning id into v_ticket;
    v_ids := array_append(v_ids, v_ticket);

    insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_ticket, 'datetime', v_ts, public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

    if v_first is null or v_date < v_first then
      v_first := v_date;
    end if;

    -- inside the window (including today): the engine assigns it now (attendance for today, leave, capacity, busy time,
    -- location). Nobody free or checked in -> the engine raises its normal "needs manual assignment" alert. A visit beyond the
    -- window waits for assign_due_amc_visits().
    if v_date <= v_today + v_window then
      begin
        perform public._auto_assign_ticket_internal(v_ticket, p_org_id, p_skip_rating_logic => true);
      exception when others then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (p_org_id, 'operation_admin', 'ticket_unassigned', 'Ticket needs manual assignment',
                format('AMC visit %s of %s could not be auto-assigned at sale (%s). Please assign it.', i, p_total_visits, left(sqlerrm, 120)),
                v_ticket);
      end;
    end if;
  end loop;

  if v_first is not null then
    update public.amc_contracts set next_service_date = v_first where id = p_contract_id;
  end if;

  -- a back-dated sale: record what was not created and tell the master. The visits are NOT silently dropped.
  if array_length(v_skipped, 1) is not null then
    update public.amc_contracts set visits_skipped = v_skipped where id = p_contract_id;
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'master', 'amc_visits_skipped', 'AMC sold with back-dated visits not scheduled',
            format('Start date %s is in the past, so %s of %s visits (visit %s) were not created. Review this contract with the customer.',
                   p_start_date, array_length(v_skipped, 1), p_total_visits, array_to_string(v_skipped, ', ')),
            p_contract_id);
  end if;

  return v_ids;
end;
$$;
revoke all on function public._schedule_amc_visits(uuid, uuid, uuid, uuid, text, integer, integer, date, date, uuid, uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public._schedule_amc_visits(uuid, uuid, uuid, uuid, text, integer, integer, date, date, uuid, uuid, text, timestamptz) to service_role;

-- ── the four generators now call the helper (bodies are the LIVE bodies; only the visit loop changed) ─────────────────

-- a new optional argument changes the signature: the 7-argument overload is dropped so the two never coexist
drop function if exists public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid);

CREATE OR REPLACE FUNCTION public.sell_amc_plan(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_start_date date DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata'::text))::date, p_years integer DEFAULT NULL::integer, p_referred_by_technician_id uuid DEFAULT NULL::uuid, p_confirm_backdated boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_plan amc_plans;
  v_years integer;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_appointment_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
  v_lead_id uuid; -- REFERRAL (new): resolved technician referral, if any
  v_customer_name text;
  v_days_back integer;
  v_max_back integer;
  v_confirmed uuid;
  v_skipped integer[];
begin
  if not (public.is_ops_staff() or public.is_sales_staff()) then
    raise exception 'sell_amc_plan: only master, operation_admin, or sales_admin may sell an AMC plan';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan: org mismatch';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'sell_amc_plan: years must be greater than zero';
  end if;

  -- back-dated start: refused beyond the threshold unless a master confirms it explicitly
  select coalesce(s.amc_backdate_max_days, 7) into v_max_back from public.settings s where s.org_id = p_org_id;
  v_max_back := coalesce(v_max_back, 7);
  v_days_back := (now() at time zone 'Asia/Kolkata')::date - p_start_date;
  if v_days_back > v_max_back then
    if not (coalesce(p_confirm_backdated, false) and public.is_master()) then
      raise exception 'AMC_BACKDATED: start date % is % days in the past (limit % days). A master must confirm a back-dated sale.',
        p_start_date, v_days_back, v_max_back using errcode = 'P0001';
    end if;
    v_confirmed := auth.uid();
  end if;

  if p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'AMC sale, referred by technician');
  end if;

  v_expiry := p_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, backdated_confirmed_by)
  values (p_org_id, p_customer_id, p_product_id, p_plan_id, p_start_date, v_expiry, 'active', p_start_date + make_interval(months => v_interval_months), v_confirmed)
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, null, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  -- The helper creates the visits (visit 1 on the start date, then every 12 / visits-per-year months) and assigns the ones
  -- inside settings.amc_assign_window_days now; later ones are assigned by assign_due_amc_visits() when they fall due.
  v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, p_customer_id, v_contract_id, p_product_id, v_plan.name,
    v_plan.visits_per_year, v_total_visits, p_start_date, v_expiry, v_address_id, v_lead_id, 'call');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold', format('%s AMC contract created with %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)), v_contract_id);

  select c.visits_skipped into v_skipped from public.amc_contracts c where c.id = v_contract_id;
  return jsonb_build_object(
    'contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry,
    'visits_expected', v_total_visits,
    'visits_created', coalesce(array_length(v_ticket_ids, 1), 0),
    -- the skipped visits, named: number and the date each would have been on
    'visits_skipped', coalesce((
      select jsonb_agg(jsonb_build_object('visit_no', k, 'would_have_been_on', public._amc_visit_date(p_start_date, v_plan.visits_per_year, k)) order by k)
        from unnest(v_skipped) as k), '[]'::jsonb),
    'backdated_confirmed', v_confirmed is not null);
end;
$function$;
revoke all on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid, boolean) from public, anon;
grant execute on function public.sell_amc_plan(uuid, uuid, uuid, uuid, date, integer, uuid, boolean) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.sell_amc_plan_onsite(p_org_id uuid, p_customer_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_method payment_method, p_txn_id text DEFAULT NULL::text, p_payment_description text DEFAULT NULL::text, p_amount_paid numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tech_id uuid;
  v_customer_name text;
  v_lead_id uuid;
  v_settings settings;
  v_plan amc_plans;
  v_effective_price numeric(12, 2);
  v_discount numeric(12, 2) := 0;
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_contract_id uuid;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_address_id uuid;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'sell_amc_plan_onsite: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'sell_amc_plan_onsite: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'sell_amc_plan_onsite: customer % not found in org %', p_customer_id, p_org_id;
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'sell_amc_plan_onsite: AMC plans are only sold on RO products';
  end if;
  if p_payment_method = 'transfer' and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'sell_amc_plan_onsite: bank transfer requires a transaction ID and description';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'sell_amc_plan_onsite: plan % not found', p_plan_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'sell_amc_plan_onsite: no settings row for org %', p_org_id;
  end if;

  select name into v_customer_name from public.customers where id = p_customer_id;
  insert into public.leads (org_id, customer_id, name, source, status, owner_id)
  values (p_org_id, p_customer_id, coalesce(v_customer_name, 'On-site AMC customer'), 'field', 'won', v_tech_id)
  returning id into v_lead_id;

  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'converted', format('On-site AMC sale (%s) by technician', v_plan.name));

  v_effective_price := coalesce(v_plan.price_per_year * v_plan.years, v_plan.price);
  v_gst := round(v_effective_price * v_settings.gst_rate / 100, 2);
  v_total := v_effective_price + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'sell_amc_plan_onsite: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'sell_amc_plan_onsite: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
  ) values (
    p_org_id, p_customer_id, 'amc', v_effective_price, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid, auth.uid()
  ) returning * into v_invoice;

  v_expiry := (now() at time zone 'Asia/Kolkata')::date + (v_plan.years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_plan.years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
  values (
    p_org_id, p_customer_id, p_product_id, p_plan_id, (now() at time zone 'Asia/Kolkata')::date,
    v_expiry, 'active', (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_interval_months), v_invoice.id
  )
  returning id into v_contract_id;

  if v_plan.gift_id is not null then
    insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_invoice.id, v_plan.gift_id);
  end if;

  select a.id into v_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

  v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, p_customer_id, v_contract_id, p_product_id, v_plan.name,
    v_plan.visits_per_year, v_total_visits, (now() at time zone 'Asia/Kolkata')::date, v_expiry, v_address_id, v_lead_id, 'field');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_sold', 'AMC plan sold on-site',
    format('%s AMC contract sold on-site by a technician, %s scheduled visits.', v_plan.name, array_length(v_ticket_ids, 1)),
    v_contract_id
  );

  return jsonb_build_object(
    'invoice_id', v_invoice.id,
    'contract_id', v_contract_id,
    'ticket_ids', to_jsonb(v_ticket_ids),
    'expiry_date', v_expiry,
    'lead_id', v_lead_id
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.renew_amc_plan(p_org_id uuid, p_product_id uuid, p_plan_id uuid, p_payment_reference text, p_years integer DEFAULT NULL::integer, p_referred_by_technician_name text DEFAULT NULL::text, p_address_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_plan amc_plans;
  v_years integer;
  v_existing amc_contracts;
  v_settings settings;
  v_start_date date;
  v_expiry date;
  v_interval_months integer;
  v_total_visits integer;
  v_visit_date date;
  v_ticket_id uuid;
  v_contract_id uuid;
  v_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_tech_id uuid;
  v_tech_match_count integer;
  v_customer_name text;
  v_lead_id uuid; -- FINDER CREDIT: resolved technician referral, if any
begin
  v_customer_id := public.current_customer_id();
  if v_customer_id is null then
    raise exception 'renew_amc_plan: caller is not a customer';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'renew_amc_plan: org mismatch';
  end if;
  if p_payment_reference is null or btrim(p_payment_reference) = '' then
    raise exception 'renew_amc_plan: a payment reference is required';
  end if;
  if not exists (select 1 from public.products where id = p_product_id and org_id = p_org_id and category = 'ro') then
    raise exception 'renew_amc_plan: AMC plans are only sold on RO products';
  end if;

  select * into v_plan from public.amc_plans where id = p_plan_id and org_id = p_org_id;
  if v_plan.id is null then
    raise exception 'renew_amc_plan: plan % not found', p_plan_id;
  end if;

  v_years := coalesce(p_years, v_plan.years);
  if v_years <= 0 then
    raise exception 'renew_amc_plan: years must be greater than zero';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;

  select * into v_existing from public.amc_contracts
  where org_id = p_org_id and customer_id = v_customer_id and product_id = p_product_id
  order by expiry_date desc limit 1;

  if v_existing.id is not null
     and v_existing.expiry_date - v_settings.amc_book_window_days > (now() at time zone 'Asia/Kolkata')::date then
    raise exception 'renew_amc_plan: renewal is only available from % (admin-set window)', v_existing.expiry_date - v_settings.amc_book_window_days;
  end if;

  if p_referred_by_technician_name is not null and btrim(p_referred_by_technician_name) <> '' then
    select count(*), min(t.id) into v_tech_match_count, v_tech_id
    from public.technicians t
    join public.profiles pr on pr.id = t.profile_id
    where t.org_id = p_org_id
      and t.is_active = true
      and pr.is_active = true
      and lower(btrim(pr.full_name)) = lower(btrim(p_referred_by_technician_name));

    if v_tech_match_count <> 1 then
      v_tech_id := null;
    end if;
  end if;

  if v_tech_id is not null then
    select name into v_customer_name from public.customers where id = v_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, 'AMC customer'), 'referral', 'won', v_tech_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', format('AMC self-service purchase, referred by %s', p_referred_by_technician_name));
  end if;

  v_start_date := greatest((now() at time zone 'Asia/Kolkata')::date, coalesce(v_existing.expiry_date, (now() at time zone 'Asia/Kolkata')::date));
  v_expiry := v_start_date + (v_years || ' years')::interval;
  v_interval_months := greatest(1, round(12.0 / v_plan.visits_per_year)::integer);
  v_total_visits := v_years * v_plan.visits_per_year;

  insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date)
  values (p_org_id, v_customer_id, p_product_id, p_plan_id, v_start_date, v_expiry, 'active', v_start_date + make_interval(months => v_interval_months))
  returning id into v_contract_id;

  if p_address_id is not null and exists (select 1 from public.addresses where id = p_address_id and customer_id = v_customer_id) then
    v_address_id := p_address_id;
  else
    select a.id into v_address_id from public.addresses a where a.customer_id = v_customer_id and a.is_primary = true limit 1;
  end if;

  v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, v_customer_id, v_contract_id, p_product_id, v_plan.name,
    v_plan.visits_per_year, v_total_visits, v_start_date, v_expiry, v_address_id, v_lead_id, 'customer_app');

  insert into public.notifications (org_id, role, type, title, body, ref_id)
  values (
    p_org_id, 'operation_admin', 'amc_renewed', 'AMC renewed via customer app',
    format('%s plan (%s years) â€” payment ref %s', v_plan.name, v_years, p_payment_reference), v_contract_id
  );

  return jsonb_build_object('contract_id', v_contract_id, 'ticket_ids', to_jsonb(v_ticket_ids), 'expiry_date', v_expiry);
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_sale(p_org_id uuid, p_customer_id uuid, p_cart jsonb, p_quotation_id uuid DEFAULT NULL::uuid, p_redeem_points integer DEFAULT 0, p_referred_by_technician_id uuid DEFAULT NULL::uuid, p_amount_paid numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_settings settings;
  v_discount_percent numeric(5, 2);
  v_payment_method payment_method;
  v_spare_invoice invoices;
  v_product_invoice invoices;
  v_amc_invoice invoices;
  v_primary_invoice_id uuid;
  v_combined_subtotal numeric(12, 2);
  v_gift_excluded_amount numeric(12, 2);
  v_gift_id uuid;
  v_gift gifts;
  v_approval_id uuid;
  v_item record;
  v_warranty_id uuid;
  v_ticket_id uuid;
  v_tech_id uuid;
  v_amc_product_id uuid;
  v_amc_plan_id uuid;
  v_amc_plan amc_plans;
  v_amc_discount numeric(12, 2);
  v_amc_gst numeric(12, 2);
  v_amc_total numeric(12, 2);
  v_amc_contract_id uuid;
  v_amc_expiry date;
  v_amc_interval_months integer;
  v_amc_total_visits integer;
  v_amc_visit_date date;
  v_amc_ticket_id uuid;
  v_amc_address_id uuid;
  v_ticket_ids uuid[] := '{}';
  v_warranty_ids uuid[] := '{}';
  v_has_amc boolean;
  v_redeem_points integer := 0;
  v_redeem_balance integer;
  v_redeem_amount numeric(12, 2) := 0;
  v_primary_invoice_total numeric(12, 2);
  v_warranty warranties;
  v_warranty_address_id uuid;
  v_warranty_total_visits integer;
  v_warranty_visit_date date;
  v_warranty_ticket_id uuid;
  v_amc_effective_price numeric(12, 2);
  v_lead_id uuid; -- FINDER CREDIT: source lead behind p_quotation_id, if any
  v_customer_name text; -- REFERRAL: only looked up if p_referred_by_technician_id is used
  v_combined_total numeric(12, 2); -- AMOUNT TRACKING: sum of every invoice's *current* total, after gift/redeem adjustments
  v_amount_paid_remaining numeric(12, 2);
  v_pay_invoice_id uuid;
  v_pay_invoice_total numeric(12, 2);
  v_pay_amount numeric(12, 2);
begin
  if not public.is_sales_staff() then
    raise exception 'create_sale: only master or sales_admin may create a sale';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_sale: org mismatch';
  end if;
  if not exists (select 1 from public.customers where id = p_customer_id and org_id = p_org_id) then
    raise exception 'create_sale: customer % not found in org %', p_customer_id, p_org_id;
  end if;

  if p_quotation_id is not null then
    select lead_id into v_lead_id from public.quotations where id = p_quotation_id and org_id = p_org_id;
  end if;

  if v_lead_id is null and p_referred_by_technician_id is not null
     and exists (select 1 from public.technicians where id = p_referred_by_technician_id and org_id = p_org_id) then
    select name into v_customer_name from public.customers where id = p_customer_id;
    insert into public.leads (org_id, customer_id, name, source, status, owner_id)
    values (p_org_id, p_customer_id, coalesce(v_customer_name, 'Sales customer'), 'referral', 'won', p_referred_by_technician_id)
    returning id into v_lead_id;

    insert into public.lead_activities (org_id, lead_id, type, note)
    values (p_org_id, v_lead_id, 'converted', 'Walk-in sale, referred by technician');
  end if;

  v_has_amc := p_cart -> 'amc' is not null and p_cart -> 'amc' <> 'null'::jsonb;
  if coalesce(jsonb_array_length(p_cart -> 'spare_items'), 0) = 0
     and coalesce(jsonb_array_length(p_cart -> 'product_items'), 0) = 0
     and not v_has_amc then
    raise exception 'create_sale: cart is empty';
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_sale: no settings row for org %', p_org_id;
  end if;

  v_discount_percent := coalesce((p_cart ->> 'discount_percent')::numeric, 0);
  if v_discount_percent < 0 then
    raise exception 'create_sale: discount cannot be negative';
  end if;
  if v_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_sale: discount % exceeds the admin limit of %', v_discount_percent, v_settings.discount_admin_max;
  end if;

  v_payment_method := nullif(p_cart ->> 'payment_method', '')::payment_method;
  if v_payment_method is null then
    raise exception 'create_sale: payment_method is required';
  end if;
  if v_payment_method = 'transfer'
     and (nullif(p_cart ->> 'txn_id', '') is null or nullif(p_cart ->> 'payment_description', '') is null) then
    raise exception 'create_sale: bank transfer requires a transaction ID and description';
  end if;

  v_redeem_points := coalesce(p_redeem_points, 0);
  if v_redeem_points < 0 then
    raise exception 'create_sale: redeem points cannot be negative';
  end if;
  if v_redeem_points > 0 then
    select coalesce(sum(points), 0) into v_redeem_balance
    from public.referral_points
    where customer_id = p_customer_id and org_id = p_org_id;

    if v_redeem_points > v_redeem_balance then
      raise exception 'create_sale: cannot redeem % referral points â€” customer % has a balance of only %', v_redeem_points, p_customer_id, v_redeem_balance;
    end if;

    v_redeem_amount := round(v_redeem_points * v_settings.referral_point_value, 2);
  end if;

  v_spare_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'spare', p_cart -> 'spare_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  v_product_invoice := public._sale_create_line_invoice(
    p_org_id, p_customer_id, 'product', p_cart -> 'product_items', v_discount_percent, v_settings.gst_rate,
    v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description'
  );

  if v_product_invoice.id is not null then
    for v_item in
      select * from jsonb_to_recordset(p_cart -> 'product_items')
        as x(item_id uuid, qty integer, warranty boolean, warranty_months integer, installation boolean)
    loop
      if coalesce(v_item.warranty, false) then
        insert into public.warranties (org_id, customer_id, product_id, start_date, expiry_date, invoice_id)
        select p_org_id, p_customer_id, v_item.item_id, (now() at time zone 'Asia/Kolkata')::date,
               (now() at time zone 'Asia/Kolkata')::date + (coalesce(v_item.warranty_months, p.warranty_months) || ' months')::interval,
               v_product_invoice.id
        from public.products p where p.id = v_item.item_id
        returning id into v_warranty_id;
        v_warranty_ids := array_append(v_warranty_ids, v_warranty_id);

        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (
          p_org_id, 'operation_admin', 'warranty_registered', 'Warranty registered',
          format('A warranty was registered from invoice %s.', v_product_invoice.id), v_warranty_id
        );

        select * into v_warranty from public.warranties where id = v_warranty_id;
        select a.id into v_warranty_address_id from public.addresses a
        where a.customer_id = p_customer_id and a.is_primary = true limit 1;

        v_warranty_total_visits := floor(
          (extract(year from age(v_warranty.expiry_date, v_warranty.start_date)) * 12
            + extract(month from age(v_warranty.expiry_date, v_warranty.start_date))) / 3.0
        )::integer;

        v_warranty_visit_date := v_warranty.start_date;
        for i in 1..v_warranty_total_visits loop
          v_warranty_visit_date := v_warranty.start_date + make_interval(months => 3 * i);
          exit when v_warranty_visit_date > v_warranty.expiry_date;
          v_warranty_visit_date := public._visit_working_day(p_org_id, v_warranty_visit_date);

          insert into public.service_tickets (
            org_id, customer_id, address_id, product_id, name_of_complaint, nature_of_complaint,
            type, priority, status, channel, lead_id, warranty_id
          ) values (
            p_org_id, p_customer_id, v_warranty_address_id, v_item.item_id,
            format('Warranty scheduled service %s of %s', i, v_warranty_total_visits), 'Warranty scheduled service',
            'warranty', 'normal', 'open', 'walk_in', v_lead_id, v_warranty_id -- FINDER CREDIT
          )
          returning id into v_warranty_ticket_id;
          v_ticket_ids := array_append(v_ticket_ids, v_warranty_ticket_id);

          insert into public.appointments (org_id, ticket_id, mode, scheduled_at, available_from, available_to, status)
    values (p_org_id, v_warranty_ticket_id, 'datetime', public._visit_start_ts(p_org_id, v_warranty_visit_date), public._visit_window_from(p_org_id), public._visit_window_to(p_org_id), 'scheduled');

          perform public._auto_assign_ticket_internal(v_warranty_ticket_id, p_org_id, p_skip_rating_logic => true);

          if i = 1 then
            update public.warranties set next_service_date = v_warranty_visit_date where id = v_warranty_id;
          end if;
        end loop;
      end if;

      if coalesce(v_item.installation, false) then
        insert into public.service_tickets (
          org_id, customer_id, product_id, brand_id, model_id,
          name_of_complaint, nature_of_complaint, type, priority, status, channel, invoice_id, lead_id
        )
        select p_org_id, p_customer_id, v_item.item_id, p.brand_id, p.model_id,
               'Installation', 'New product installation', 'installation', 'normal', 'open', 'walk_in', v_product_invoice.id, v_lead_id -- FINDER CREDIT
        from public.products p where p.id = v_item.item_id
        returning id into v_ticket_id;
        v_ticket_ids := array_append(v_ticket_ids, v_ticket_id);

        select t.id into v_tech_id
        from public.technicians t
        where t.org_id = p_org_id and t.is_active = true
          and exists (
            select 1 from public.attendance a
            where a.technician_id = t.id and a.org_id = p_org_id and a.date = (now() at time zone 'Asia/Kolkata')::date
              and a.check_in_at is not null and a.check_out_at is null
          )
          and not public._tech_busy_at(t.id, null, null, null)
        order by t.created_at
        for update skip locked
        limit 1;

        if v_tech_id is not null then
          insert into public.appointments (org_id, ticket_id, technician_id, mode, status)
          values (p_org_id, v_ticket_id, v_tech_id, 'always', 'scheduled');
          update public.service_tickets set status = 'assigned' where id = v_ticket_id;
        else
          insert into public.notifications (org_id, role, type, title, body, ref_id)
          values (
            p_org_id, 'operation_admin', 'installation_unassigned', 'Installation needs manual assignment',
            'No on-duty technician is free right now â€” assign this installation manually.', v_ticket_id
          );
        end if;
      end if;
    end loop;
  end if;

  if v_has_amc then
    v_amc_product_id := (p_cart -> 'amc' ->> 'product_id')::uuid;
    v_amc_plan_id := (p_cart -> 'amc' ->> 'plan_id')::uuid;

    if not exists (select 1 from public.products where id = v_amc_product_id and org_id = p_org_id and category = 'ro') then
      raise exception 'create_sale: AMC add-on is only available on RO products';
    end if;

    select * into v_amc_plan from public.amc_plans where id = v_amc_plan_id and org_id = p_org_id;
    if v_amc_plan is null then
      raise exception 'create_sale: AMC plan % not found', v_amc_plan_id;
    end if;

    v_amc_effective_price := coalesce(v_amc_plan.price_per_year * v_amc_plan.years, v_amc_plan.price);

    v_amc_discount := round(v_amc_effective_price * v_discount_percent / 100, 2);
    v_amc_gst := round((v_amc_effective_price - v_amc_discount) * v_settings.gst_rate / 100, 2);
    v_amc_total := v_amc_effective_price - v_amc_discount + v_amc_gst;

    insert into public.invoices (
      org_id, customer_id, type, subtotal, discount, gst, total,
      payment_method, txn_id, payment_description, payment_status, amount_paid, sold_by
    ) values (
      p_org_id, p_customer_id, 'amc', v_amc_effective_price, v_amc_discount, v_amc_gst, v_amc_total,
      v_payment_method, p_cart ->> 'txn_id', p_cart ->> 'payment_description', 'paid', v_amc_total, auth.uid()
    ) returning * into v_amc_invoice;

    v_amc_expiry := (now() at time zone 'Asia/Kolkata')::date + (v_amc_plan.years || ' years')::interval;
    v_amc_interval_months := greatest(1, round(12.0 / v_amc_plan.visits_per_year)::integer);
    v_amc_total_visits := v_amc_plan.years * v_amc_plan.visits_per_year;

    insert into public.amc_contracts (org_id, customer_id, product_id, plan_id, start_date, expiry_date, status, next_service_date, invoice_id)
    values (
      p_org_id, p_customer_id, v_amc_product_id, v_amc_plan_id, (now() at time zone 'Asia/Kolkata')::date,
      v_amc_expiry, 'active',
      (now() at time zone 'Asia/Kolkata')::date + make_interval(months => v_amc_interval_months),
      v_amc_invoice.id
    )
    returning id into v_amc_contract_id;

    if v_amc_plan.gift_id is not null then
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_amc_invoice.id, v_amc_plan.gift_id);
    end if;

    select a.id into v_amc_address_id from public.addresses a where a.customer_id = p_customer_id and a.is_primary = true limit 1;

    v_ticket_ids := v_ticket_ids || public._schedule_amc_visits(p_org_id, p_customer_id, v_amc_contract_id, v_amc_product_id, v_amc_plan.name,
      v_amc_plan.visits_per_year, v_amc_total_visits, (now() at time zone 'Asia/Kolkata')::date, v_amc_expiry, v_amc_address_id, v_lead_id, 'walk_in');
  end if;

  v_primary_invoice_id := coalesce(v_product_invoice.id, v_spare_invoice.id, v_amc_invoice.id);
  v_combined_subtotal := coalesce(v_product_invoice.subtotal, 0) + coalesce(v_spare_invoice.subtotal, 0) + coalesce(v_amc_invoice.subtotal, 0);

  v_gift_excluded_amount := 0;
  if v_product_invoice.id is not null then
    select coalesce(sum(p.price * x.qty), 0) into v_gift_excluded_amount
    from jsonb_to_recordset(p_cart -> 'product_items') as x(item_id uuid, qty integer, warranty boolean, warranty_months integer, installation boolean)
    join public.products p on p.id = x.item_id and p.org_id = p_org_id
    where exists (
      select 1 from public.gift_exclusion_products gep
      where gep.org_id = p_org_id and gep.product_id = x.item_id and gep.is_active = true
    );
  end if;

  v_gift_id := nullif(p_cart ->> 'gift_id', '')::uuid;
  if v_gift_id is not null and v_primary_invoice_id is not null then
    select * into v_gift from public.gifts where id = v_gift_id and org_id = p_org_id;
    if v_gift is not null and (v_combined_subtotal - v_gift_excluded_amount) >= v_gift.threshold_amount then
      update public.invoices set gift_id = v_gift_id where id = v_primary_invoice_id;
      insert into public.gift_logs (org_id, invoice_id, gift_id) values (p_org_id, v_primary_invoice_id, v_gift_id);
    end if;
  end if;

  if v_redeem_points > 0 then
    if v_primary_invoice_id is null then
      raise exception 'create_sale: cannot redeem referral points â€” the cart produced no invoice to apply them to';
    end if;

    select total into v_primary_invoice_total from public.invoices where id = v_primary_invoice_id;
    v_redeem_amount := least(v_redeem_amount, v_primary_invoice_total);

    update public.invoices set total = total - v_redeem_amount where id = v_primary_invoice_id;

    insert into public.referral_points (org_id, customer_id, points, reason, ref_id)
    values (p_org_id, p_customer_id, -v_redeem_points, 'redeemed_on_sale', v_primary_invoice_id);
  end if;

  v_combined_total := 0;
  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_combined_total := v_combined_total + v_pay_invoice_total;
  end loop;

  v_amount_paid_remaining := coalesce(p_amount_paid, v_combined_total);
  if v_amount_paid_remaining < 0 then
    raise exception 'create_sale: amount_paid cannot be negative';
  end if;
  if v_amount_paid_remaining > v_combined_total then
    raise exception 'create_sale: amount_paid (%) cannot exceed the combined invoice total (%)', v_amount_paid_remaining, v_combined_total;
  end if;

  for v_pay_invoice_id in
    select unnest(array_remove(array[v_spare_invoice.id, v_product_invoice.id, v_amc_invoice.id], null))
  loop
    select total into v_pay_invoice_total from public.invoices where id = v_pay_invoice_id;
    v_pay_amount := least(v_amount_paid_remaining, v_pay_invoice_total);
    update public.invoices
      set amount_paid = v_pay_amount,
          payment_status = public._derive_payment_status(v_pay_amount, v_pay_invoice_total)
      where id = v_pay_invoice_id;
    v_amount_paid_remaining := v_amount_paid_remaining - v_pay_amount;
  end loop;

  if v_discount_percent > v_settings.discount_tech_max and v_primary_invoice_id is not null then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_primary_invoice_id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  if p_quotation_id is not null then
    update public.quotations set status = 'converted' where id = p_quotation_id and org_id = p_org_id;

    if v_lead_id is not null then
      update public.leads set status = 'won', updated_at = now() where id = v_lead_id and org_id = p_org_id;
    end if;
  end if;

  return jsonb_build_object(
    'spare_invoice_id', v_spare_invoice.id,
    'product_invoice_id', v_product_invoice.id,
    'amc_invoice_id', v_amc_invoice.id,
    'warranty_ids', to_jsonb(v_warranty_ids),
    'ticket_ids', to_jsonb(v_ticket_ids),
    'approval_id', v_approval_id,
    'redeemed_points', v_redeem_points,
    'redeemed_amount', v_redeem_amount
  );
end;
$function$;

-- ── assign visits that are due ──────────────────────────────────────────────────────────────────────────────────────────
-- Runs the SAME engine the rest of the app uses (_auto_assign_ticket_internal, rating logic skipped as before), only for
-- open, unassigned, scheduled contract visits dated on or before today + amc_assign_window_days (IST). Past-due visits are
-- included (they should have been assigned). Each ticket is its own sub-transaction.
create or replace function public.assign_due_amc_visits(p_now timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r            record;
  v_res        jsonb;
  v_tried      integer := 0;
  v_assigned   integer := 0;
  v_unassigned integer := 0;
  v_errors     integer := 0;
begin
  for r in
    select t.id as ticket_id, t.org_id
      from public.service_tickets t
      join public.appointments a on a.ticket_id = t.id
      join public.settings s on s.org_id = t.org_id
     where t.contract_id is not null
       and t.type = 'amc'
       and t.status = 'open'
       and a.status = 'scheduled'
       and a.technician_id is null
       and a.scheduled_at is not null
       and (a.scheduled_at at time zone 'Asia/Kolkata')::date
             <= (p_now at time zone 'Asia/Kolkata')::date + s.amc_assign_window_days
     order by a.scheduled_at, t.created_at, t.id
  loop
    v_tried := v_tried + 1;
    begin
      v_res := public._auto_assign_ticket_internal(r.ticket_id, r.org_id, p_skip_rating_logic => true);
      if coalesce((v_res ->> 'assigned')::boolean, false) then
        v_assigned := v_assigned + 1;
      else
        v_unassigned := v_unassigned + 1;
        -- the engine raises a "needs manual assignment" alert on every attempt; keep only the oldest unread one per ticket
        delete from public.notifications n
         where n.id in (
                 select x.id from public.notifications x
                  where x.type = 'ticket_unassigned' and x.ref_id = r.ticket_id and x.is_read = false
                  order by x.created_at, x.id
                  offset 1);
      end if;
    exception when others then
      v_errors := v_errors + 1;
    end;
  end loop;

  return jsonb_build_object('tried', v_tried, 'assigned', v_assigned, 'still_unassigned', v_unassigned, 'errors', v_errors);
end;
$$;
revoke all on function public.assign_due_amc_visits(timestamptz) from public, anon, authenticated;
grant execute on function public.assign_due_amc_visits(timestamptz) to service_role;

-- ── re-check one visit when it is rescheduled ───────────────────────────────────────────────────────────────────────────
create or replace function public._trg_amc_visit_rescheduled()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  v_window integer;
begin
  begin
    if new.technician_id is null and new.status = 'scheduled' and new.scheduled_at is not null then
      select st.id, st.org_id, st.contract_id, st.type, st.status into t from public.service_tickets st where st.id = new.ticket_id;
      if t.contract_id is not null and t.type = 'amc' and t.status = 'open' then
        select s.amc_assign_window_days into v_window from public.settings s where s.org_id = t.org_id;
        if (new.scheduled_at at time zone 'Asia/Kolkata')::date
             <= (now() at time zone 'Asia/Kolkata')::date + coalesce(v_window, 7) then
          perform public._auto_assign_ticket_internal(t.id, t.org_id, p_skip_rating_logic => true);
        end if;
      end if;
    end if;
  exception when others then
    -- a failed re-check must never block the reschedule itself; the daily job will pick the visit up
    null;
  end;
  return null;
end;
$$;
revoke all on function public._trg_amc_visit_rescheduled() from public, anon, authenticated;
drop trigger if exists zz_amc_visit_rescheduled on public.appointments;
create trigger zz_amc_visit_rescheduled
  after update of scheduled_at on public.appointments
  for each row when (old.scheduled_at is distinct from new.scheduled_at)
  execute function public._trg_amc_visit_rescheduled();

-- ── cron: tick with heartbeat, and a dead-man check ─────────────────────────────────────────────────────────────────────
create or replace function public.amc_assign_cron_tick(p_job_key text default 'amc_assign_due_visits')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.assign_due_amc_visits();
  exception when others then
    insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error)
    values (p_job_key, clock_timestamp(), 'error', left(sqlerrm, 500))
    on conflict (job_key) do update
      set last_run_at = excluded.last_run_at, last_status = 'error', last_error = excluded.last_error;
    return;
  end;
  insert into public.cron_job_heartbeats (job_key, last_run_at, last_status, last_error, last_stale_alert_at)
  values (p_job_key, clock_timestamp(), 'ok', null, null)
  on conflict (job_key) do update
    set last_run_at = excluded.last_run_at, last_status = 'ok', last_error = null, last_stale_alert_at = null;
end;
$$;
revoke all on function public.amc_assign_cron_tick(text) from public, anon, authenticated;
grant execute on function public.amc_assign_cron_tick(text) to service_role;

-- daily job: stale after 26 hours (one missed morning plus slack), alert at most once every 24 hours
create or replace function public._amc_assign_deadman_check(p_job_key text default 'amc_assign_due_visits')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now  timestamptz := clock_timestamp();
  v_last timestamptz;
  v_stat text;
  v_err  text;
begin
  update public.cron_job_heartbeats h
     set last_stale_alert_at = v_now
   where h.job_key = p_job_key
     and (h.last_run_at is null or h.last_run_at < v_now - interval '26 hours' or h.last_status = 'error')
     and (h.last_stale_alert_at is null or h.last_stale_alert_at < v_now - interval '24 hours')
  returning h.last_run_at, h.last_status, h.last_error into v_last, v_stat, v_err;
  if not found then
    return;
  end if;
  insert into public.notifications (org_id, role, type, title, body)
  select o.id, 'master', 'cron_job_stale', format('Cron job "%s" looks stuck', p_job_key),
         case when v_stat = 'error' then format('%s: its last run failed: %s', p_job_key, coalesce(v_err, 'unknown error'))
              else format('%s: has not run in over 26 hours (expected daily at 06:30 IST); AMC visits due soon may be unassigned', p_job_key) end
    from public.organizations o;
exception when others then
  null;
end;
$$;
revoke all on function public._amc_assign_deadman_check(text) from public, anon, authenticated;
grant execute on function public._amc_assign_deadman_check(text) to service_role;

-- ── legacy milestone and automation emit: skip contract visit tickets ─────────────────────────────────────────────────

-- The legacy milestone function is NOT re-issued (it inserts the optimistic 'sent' rows the dispatcher guard freezes). Instead the
-- single INSERT-or-UPDATE trigger is split in two: the INSERT half skips contract visit tickets by a WHEN condition; the
-- status half is unchanged, so "assigned" still goes out when a visit is assigned near its date.
drop trigger if exists service_tickets_milestone_notify on public.service_tickets;
create trigger service_tickets_milestone_notify
  after insert on public.service_tickets
  for each row when (new.contract_id is null)
  execute function public._milestone_ticket_notify();
create trigger service_tickets_milestone_notify_status
  after update of status on public.service_tickets
  for each row
  execute function public._milestone_ticket_notify();

CREATE OR REPLACE FUNCTION public._trg_automation_emit_ticket()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tech uuid;
begin
  begin
    if tg_op = 'INSERT' then
      -- contract visit tickets are covered by amc.joined; do not emit ticket.created once per visit
      if new.contract_id is not null then
        return null;
      end if;
      perform public.automation_emit(new.org_id, 'ticket.created', 'ticket', new.id, new.customer_id, 'created',
        jsonb_build_object('ticket_type', new.type::text, 'priority', new.priority::text, 'channel', new.channel::text,
                           'product_id', new.product_id, 'status', new.status::text));
    elsif new.status is distinct from old.status and new.status::text in ('assigned', 'completed', 'cancelled') then
      select a.technician_id into v_tech from public.appointments a where a.ticket_id = new.id order by a.created_at desc limit 1;
      perform public.automation_emit(new.org_id, 'ticket.' || new.status::text, 'ticket', new.id, new.customer_id, new.status::text,
        jsonb_build_object('ticket_type', new.type::text, 'priority', new.priority::text, 'channel', new.channel::text,
                           'product_id', new.product_id, 'status', new.status::text, 'technician_id', v_tech,
                           'has_lead', new.lead_id is not null));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, null, 'ticket', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$function$;

-- ── KPI: far-away AMC visits are not counted in open_tickets (live body, one added condition) ─────────────────────────

CREATE OR REPLACE FUNCTION public.report_kpi_tiles(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org uuid := public._report_org();                    -- raises unless an active master / operation_admin / sales_admin
  v_role text := public.current_role()::text;
  v_master boolean := (v_role = 'master');
  v_ops boolean := (v_role in ('master', 'operation_admin'));
  v_from timestamptz;
  v_to timestamptz;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_sales jsonb;
  v_service jsonb;
  v_money jsonb;
  v_funnel jsonb;
  v_ops_res jsonb;
  v_fb jsonb;
  v_cust jsonb;
  v_inv_total numeric;
  v_inv_gst numeric;
  v_coll_total numeric;
  v_coll_net numeric;
  v_exp_total numeric;
  v_won integer;
  v_leads integer;
begin
  if p_from is null or p_to is null then
    raise exception 'report_kpi_tiles: p_from and p_to are required';
  end if;
  if p_to < p_from then
    raise exception 'report_kpi_tiles: p_to must not be before p_from';
  end if;
  v_from := public._report_ist_start(p_from);
  v_to := public._report_ist_start(p_to + 1);

  -- ── sales group ────────────────────────────────────────────────────────────────────────────────────────────────────
  if v_role in ('master', 'operation_admin', 'sales_admin') then
    with b as (
      select * from public._report_invoice_base(v_org, v_from, v_to)
    ),
    lines as (
      -- line revenue of the window's counter-sale (class sales) invoices, by item type
      select ii.item_type::text as item_type,
             sum(ii.qty * ii.price - ii.discount) as revenue,
             sum(ii.qty) as qty
      from public.invoice_items ii
      join b on b.invoice_id = ii.invoice_id and b.class = 'sales'
      where ii.org_id = v_org
      group by ii.item_type
    ),
    cls as (
      select class, count(*) as cnt, sum(total) as total from b group by class
    )
    select jsonb_build_object(
      'invoiced', jsonb_build_object(
        'count', (select count(*) from b),
        'total', (select coalesce(sum(total), 0) from b),
        'gst', (select coalesce(sum(gst), 0) from b),
        'net', (select coalesce(sum(total) - sum(gst), 0) from b)),
      'collected', jsonb_build_object(
        'total', (select coalesce(sum(amount_paid), 0) from b),
        'net', (select coalesce(sum(amount_paid) - round(sum(case when total > 0 then amount_paid * gst / total else 0 end), 2), 0) from b)),
      -- tile 3, live: every unpaid or part-paid invoice of a non-test customer, whatever its date
      'outstanding', (
        select jsonb_build_object(
          'amount', coalesce(sum(i.total - i.amount_paid), 0),
          'invoice_count', count(*),
          'oldest_invoice_date', min((i.created_at at time zone 'Asia/Kolkata')::date))
        from public.invoices i
        where i.org_id = v_org and i.payment_status <> 'paid' and i.total - i.amount_paid > 0
          and not public.is_test_customer(i.customer_id)),
      -- tile 7. product + spare + gst_and_adjustments = the whole "sales" class; the five streams add up to invoiced.total
      'streams', jsonb_build_object(
        'product', (select coalesce(sum(revenue), 0) from lines where item_type = 'product'),
        'spare_counter', (select coalesce(sum(revenue), 0) from lines where item_type = 'spare'),
        'gst_and_adjustments', (select coalesce((select total from cls where class = 'sales'), 0) - coalesce(sum(revenue), 0) from lines),
        'service', coalesce((select total from cls where class = 'service'), 0),
        'amc', coalesce((select total from cls where class = 'amc'), 0),
        'rental', coalesce((select total from cls where class = 'rental'), 0),
        'note', 'Spares used on a service visit count as Service, not as Spare.'),
      -- tile 8
      'units_sold', (select coalesce(sum(qty), 0) from lines where item_type = 'product'),
      'avg_sale_value', (select case when coalesce((select cnt from cls where class = 'sales'), 0) > 0
                                     then round((select total from cls where class = 'sales') / (select cnt from cls where class = 'sales'), 2) else 0 end)
    ) into v_sales;

    -- tiles 9, 10 (composed)
    v_funnel := public.get_lead_funnel(v_from, v_to - interval '1 microsecond');
    v_leads := coalesce((v_funnel->>'total')::integer, 0);
    v_won := coalesce((v_funnel #>> '{by_status,won}')::integer, 0);
    -- tile 16 (composed)
    v_cust := public.report_customer_totals(p_from, p_to);

    v_sales := v_sales || jsonb_build_object(
      'leads', jsonb_build_object(
        'new', v_leads,
        'won', v_won,
        'lost', coalesce((v_funnel #>> '{by_status,lost}')::integer, 0),
        'won_percent', case when v_leads > 0 then round(v_won * 100.0 / v_leads, 1) end),
      'repeat_buyers', jsonb_build_object(
        'buying_customers', v_cust->'buying_customers',
        'repeat_buyers', v_cust->'repeat_buyers',
        'new_buyers', v_cust->'new_buyers',
        'repeat_rate_percent', v_cust->'repeat_rate_percent'));
  end if;

  -- ── service group ──────────────────────────────────────────────────────────────────────────────────────────────────
  if v_ops then
    v_ops_res := public.report_ops_resolution(p_from, p_to);
    v_fb := public.report_feedback(p_from, p_to);
    select jsonb_build_object(
      -- tile 12, live
      'open_tickets', (
        select jsonb_build_object(
          'count', count(*),
          'urgent', count(*) filter (where t.priority in ('very_urgent', 'urgent')),
          'past_sla', count(*) filter (where t.sla_due_at is not null and t.sla_due_at < now()))
        from public.service_tickets t
        where t.org_id = v_org and t.status in ('open', 'assigned', 'in_progress')
          and not public.is_test_customer(t.customer_id)
          and not public._ticket_is_future_amc_visit(t.id)),
      -- tile 13
      'resolved_within_24h', jsonb_build_object(
        'resolved', v_ops_res->'resolved_within_24h',
        'completed', v_ops_res->'total_completed',
        'percent', v_ops_res->'percent'),
      -- tile 14
      'rating', jsonb_build_object(
        'average', v_fb->'average_rating',
        'count', (select coalesce(sum((s->>'count')::integer), 0) from jsonb_array_elements(v_fb->'stars_distribution') s),
        'below_4_5', jsonb_array_length(coalesce(v_fb->'low_rating_entries', '[]'::jsonb))),
      -- tile 15, live counts + the window's AMC revenue
      'amc', jsonb_build_object(
        'active', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.start_date <= v_today and c.expiry_date >= v_today),
        'renewal_window', (select count(*) from public.amc_contracts c
                    where c.org_id = v_org and c.cancelled_at is null and not public.is_test_customer(c.customer_id)
                      and c.status = 'due_soon' and c.expiry_date >= v_today),
        'revenue', (select coalesce(sum(b.total), 0) from public._report_invoice_base(v_org, v_from, v_to) b where b.class = 'amc'))
    ) into v_service;
  end if;

  -- ── money-out group (master only) ─────────────────────────────────────────────────────────────────────────────────
  if v_master then
    select coalesce(sum(b.total), 0), coalesce(sum(b.gst), 0), coalesce(sum(b.amount_paid), 0),
           coalesce(sum(b.amount_paid) - round(sum(case when b.total > 0 then b.amount_paid * b.gst / b.total else 0 end), 2), 0)
      into v_inv_total, v_inv_gst, v_coll_total, v_coll_net
    from public._report_invoice_base(v_org, v_from, v_to) b;

    select coalesce(sum(amount), 0) into v_exp_total
    from public.expenses where org_id = v_org and date >= p_from and date <= p_to;

    with it as (
      select qty, price, discount, cost
      from public.invoice_items
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and not public._invoice_is_test(invoice_id)
    ),
    gl as (
      select cost
      from public.gift_logs
      where org_id = v_org and created_at >= v_from and created_at < v_to
        and (invoice_id is null or not public._invoice_is_test(invoice_id))
    ),
    m as (
      select (select coalesce(sum(qty * price - discount), 0) from it where cost is not null) as revenue,
             (select coalesce(sum(qty * cost), 0) from it where cost is not null) as cost,
             (select coalesce(sum(cost), 0) from gl where cost is not null) as gifts,
             (select count(*) from it where cost is null) + (select count(*) from gl where cost is null) as missing
    )
    select jsonb_build_object(
      -- tile 4
      'spend', jsonb_build_object(
        'total', v_exp_total,
        'by_category', coalesce((
          select jsonb_agg(jsonb_build_object('category', e.category, 'amount', e.amount) order by e.amount desc, e.category)
          from (select category, sum(amount) as amount from public.expenses
                where org_id = v_org and date >= p_from and date <= p_to group by category) e), '[]'::jsonb),
        'operating_excl_purchase', (select coalesce(sum(amount), 0) from public.expenses
                                     where org_id = v_org and date >= p_from and date <= p_to and category <> 'purchase')),
      -- tile 5: cash basis (Q1)
      'cash_profit', jsonb_build_object('collected_net', v_coll_net, 'spend', v_exp_total, 'profit', v_coll_net - v_exp_total),
      -- tile 6
      'item_margin', jsonb_build_object(
        'revenue', m.revenue, 'cost', m.cost, 'gifts_cost', m.gifts,
        'profit', m.revenue - m.cost - m.gifts,
        'margin_percent', case when m.revenue > 0 then round((m.revenue - m.cost - m.gifts) / m.revenue * 100, 1) end,
        'missing_cost_count', m.missing,
        'cost_missing', m.missing > 0)
    ) into v_money
    from m;
  end if;

  return jsonb_build_object(
    'window', jsonb_build_object('from', p_from, 'to', p_to, 'today_ist', v_today),
    'role', v_role,
    'sales', v_sales,          -- null for a caller who may not see it
    'service', v_service,
    'money_out', v_money);
end;
$function$;

-- ── cron registration (pg_cron runs in UTC: 01:00 UTC = 06:30 IST, 03:00 UTC = 08:30 IST) ────────────────────────────────
-- Idempotent: any existing job of the same name is replaced. A heartbeat row is created now so the dead-man check has a
-- baseline (never run = alert only after 26 hours from this migration, not immediately).
insert into public.cron_job_heartbeats (job_key, last_run_at, last_status)
values ('amc_assign_due_visits', clock_timestamp(), 'ok')
on conflict (job_key) do nothing;

do $cron$
begin
  perform cron.unschedule(jobid) from cron.job where jobname in ('amc-assign-due-visits', 'amc-assign-deadman');
  perform cron.schedule('amc-assign-due-visits', '0 1 * * *', 'select public.amc_assign_cron_tick()');
  perform cron.schedule('amc-assign-deadman',     '0 3 * * *', 'select public._amc_assign_deadman_check()');
end
$cron$;

notify pgrst, 'reload schema';
