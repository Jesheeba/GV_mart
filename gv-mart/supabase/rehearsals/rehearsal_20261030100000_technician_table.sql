-- REHEARSAL (NOT RUN; for the owner's approval of this exact text): technician table: migration 20261030100000 + its tests
-- One request, one DO block. It: (1) refuses to run before 18:00 IST (the clock is read from clock_timestamp()), (2) recomputes
-- the sha256 of every embedded file and refuses on any mismatch with the pinned value, (3) executes the migration text(s) and then the
-- test file in order, (4) always ends in an unconditional RAISE EXCEPTION, so nothing is ever committed.
-- No top-level begin / commit / savepoint / rollback. No schema_migrations row is written. Never concatenated with test code outside
-- this wrapper. Expected error text starts with RESULTS (or TIMING); anything else is a failure and also rolls back.
-- Pinned (sha256 of the LF blob at the commit this wrapper was generated from):
--   1480f8ad5659040df86693c9042313aa87ac55b4df50ad891aa576507092bbe6  gv-mart/supabase/migrations/20261030100000_technician_table.sql
--   c6e9aefc559365a8774216b831029e868f2fc6e808639233c272bf56c6925a4d  gv-mart/supabase/tests/technician_table.test.sql

do $rehearsal$
declare
  v_ist time := (clock_timestamp() at time zone 'Asia/Kolkata')::time;
  v_text text;
  v_hash text;
begin
  if v_ist < time '18:00' then
    raise exception 'REHEARSAL_REFUSED: the clock reads % IST, before 18:00 IST', to_char(v_ist, 'HH24:MI:SS');
  end if;

  v_text := $rh0$-- Technician table (batch-17 item 15, owner definitions 2026-10-15). Design: gv-mart/docs/design-technician-table.md
--
--   org_holidays                    master-kept list of holidays ("minus holidays if any"; empty = none).
--   invoices.referred_by_technician_id  who brought the customer, stamped at invoice creation, FORWARD-ONLY.
--   _trg_invoice_stamp_referral     BEFORE INSERT on invoices: sets that column from the customer's technician-referral lead.
--   report_technician_table(from,to)  one row per technician for a date range (ops staff, read-only).
--
-- Definitions (owner):
--   revenue       = the invoice totals (invoices.total) of COMPLETED jobs. A completed ticket's invoice is credited to the technician
--                   of the ticket's last finished visit, in the period of that visit's end (IST). Not service_charge, not collected.
--   working days  = Monday to Saturday between the period start and min(period end, YESTERDAY IST) (completed days only; today is
--                   never counted), minus org_holidays, counted from the day the technician record was created in the system
--                   (technicians has no joining-date field; a technician who joined earlier than their record shows is counted
--                   from the record date, and the screen says so).
--   absent days   = working days minus the working days the technician was present (an attendance check-in) or on leave
--                   (technician_availability status 'leave'). A day that is both present and leave counts once.
--   real sales    = this schema has NO void / cancelled / draft invoice state: payment_status is only paid | partial | due, and all
--                   three are sales (a due invoice is a receivable, not a void one). What can make an invoice not a real sale is
--                   its ticket: an invoice attached to a ticket that is not completed (cancelled, open ...) is left out of revenue,
--                   the invoiced count and every referral sum. Invoices not tied to any ticket (sales, AMC) always count.
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
  v_end := least(p_to, v_today - 1);          -- completed days only: today is never counted

  return query
  with techs as (
    select t.id, coalesce(pr.full_name, '—') as nm, t.is_active,
           greatest(p_from, (t.created_at at time zone 'Asia/Kolkata')::date) as d_from
      from public.technicians t
      left join public.profiles pr on pr.id = t.profile_id
     where t.org_id = v_org
  ),
  days as (        -- Monday to Saturday, from the technician's record date, up to yesterday
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
       and not exists (select 1 from public.service_tickets st where st.invoice_id = i.id and st.status <> 'completed')
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
$rh0$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> '1480f8ad5659040df86693c9042313aa87ac55b4df50ad891aa576507092bbe6' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for 20261030100000_technician_table.sql: %', v_hash;
  end if;
  execute v_text;

  v_text := $rh1$-- DB tests for 20261030100000_technician_table. NOT RUN (written for review). Run only through the approved rehearsal wrapper
-- (migration then this file, one request, ends in an unconditional RAISE). Throwaway __TEST_ organisations only.
create temp table res (n serial, line text);
grant all on res to public;
grant usage on sequence res_n_seq to public;
create function pg_temp.chk(p_name text, p_ok boolean, p_info text default '') returns void language plpgsql as $f$
begin insert into pg_temp.res(line) values (case when coalesce(p_ok,false) then 'PASS  ' else 'FAIL  ' end || p_name || case when p_info <> '' then '  [' || p_info || ']' else '' end); end $f$;
create function pg_temp.mkuser(p_role text, p_org uuid) returns uuid language plpgsql as $f$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '__t_' || p_role || '_' || v || '@test.invalid', 'x', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, org_id, full_name, role, is_active) values (v, p_org, '__TEST_ ' || p_role, p_role::public.user_role, true)
    on conflict (id) do update set role = excluded.role, is_active = true, org_id = excluded.org_id;
  return v;
end $f$;
create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true); execute 'set local role authenticated'; end $f$;
create function pg_temp.as_anon() returns void language plpgsql as $f$
begin perform set_config('request.jwt.claims', '', true); execute 'set local role anon'; end $f$;
create function pg_temp.as_pg() returns void language plpgsql as $f$
begin execute 'reset role'; perform set_config('request.jwt.claims', '', true); end $f$;
create function pg_temp.raises(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null;
exception when others then return sqlerrm; end $f$;
-- a completed ticket with one finished visit by p_tech and an invoice of p_total, finished on p_day
create function pg_temp.job(p_org uuid, p_cust uuid, p_tech uuid, p_total numeric, p_day date, p_type text default 'spare') returns uuid language plpgsql as $f$
declare t uuid; v uuid; i uuid;
begin
  insert into public.invoices (org_id, customer_id, type, subtotal, total, payment_status) values (p_org, p_cust, p_type::public.invoice_type, p_total, p_total, 'due') returning id into i;
  insert into public.service_tickets (org_id, customer_id, type, name_of_complaint, invoice_id) values (p_org, p_cust, 'paid', '__TEST_ job', i) returning id into t;
  insert into public.service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (p_org, t, p_tech, (p_day::timestamp + interval '10 hours') at time zone 'Asia/Kolkata', (p_day::timestamp + interval '11 hours') at time zone 'Asia/Kolkata') returning id into v;
  update public.service_tickets set status = 'completed' where id = t;
  return v;
end $f$;

do $t$
declare
  v_org uuid; v_org2 uuid; v_master uuid; v_ops uuid; v_sales uuid; v_cr uuid; v_master2 uuid;
  v_p1 uuid; v_p2 uuid; v_t1 uuid; v_t2 uuid; v_c uuid; v_ctest uuid; v_cref uuid;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_mon date; v_from date; v_to date; v_vis uuid; v_inv uuid;
  r record; s text; n int;
begin
  -- the Monday of the week before last: a fixed 12-day window Monday..Saturday of the following week, all in the past
  v_mon := v_today - ((extract(isodow from v_today)::int - 1) + 14);
  v_from := v_mon;                 -- Monday
  v_to := v_mon + 12;              -- Saturday of the next week (Mon..Sat, Sun, Mon..Sat = 12 working days)

  insert into organizations (name) values ('__TEST_techtable') returning id into v_org;
  insert into organizations (name) values ('__TEST_techtable_other') returning id into v_org2;
  insert into settings (org_id) values (v_org) on conflict (org_id) do nothing;
  insert into settings (org_id) values (v_org2) on conflict (org_id) do nothing;
  v_master := pg_temp.mkuser('master', v_org);
  v_master2 := pg_temp.mkuser('master', v_org2);
  v_ops := pg_temp.mkuser('operation_admin', v_org);
  v_sales := pg_temp.mkuser('sales_admin', v_org);
  v_cr := pg_temp.mkuser('customer', v_org);
  v_p1 := pg_temp.mkuser('technician', v_org);
  v_p2 := pg_temp.mkuser('technician', v_org);
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p1, true) returning id into v_t1;
  insert into technicians (org_id, profile_id, is_active) values (v_org, v_p2, true) returning id into v_t2;
  -- technicians created long ago, so every day in the window counts
  update technicians set created_at = now() - interval '200 days' where id in (v_t1, v_t2);
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ c', '9400000096') returning id into v_c;
  insert into customers (org_id, name, mobile, is_test) values (v_org, '__TEST_ flagged', '9400000097', true) returning id into v_ctest;
  insert into customers (org_id, name, mobile) values (v_org, '__TEST_ referred', '9400000098') returning id into v_cref;

  -- ---------- structure and grants ----------
  perform pg_temp.chk('org_holidays exists with RLS; invoices.referred_by_technician_id exists, nullable',
    exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = 'org_holidays' and c.relrowsecurity)
    and (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'referred_by_technician_id') = 'YES');
  perform pg_temp.chk('report_technician_table: authenticated and service_role yes, anon and PUBLIC no',
    has_function_privilege('authenticated', 'public.report_technician_table(date,date)', 'execute')
    and not has_function_privilege('anon', 'public.report_technician_table(date,date)', 'execute')
    and not exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.pronamespace = 'public'::regnamespace and a.grantee = 0
                     and p.proname in ('report_technician_table', '_trg_invoice_stamp_referral'))
    and not has_function_privilege('authenticated', 'public._trg_invoice_stamp_referral()', 'execute'));
  perform pg_temp.chk('no Google-review column in the result',
    not exists (select 1 from pg_proc p, unnest(p.proargnames) a where p.proname = 'report_technician_table' and p.pronamespace = 'public'::regnamespace
                 and (a ilike '%google%' or a ilike '%review%')));

  -- ---------- attendance: present, leave, holiday, absent ----------
  -- window = 12 working days (Mon..Sat twice). t1: present 5 days, leave 2 days (one of them also present), 1 holiday
  insert into attendance (org_id, technician_id, date, check_in_at)
    select v_org, v_t1, v_from + k, now() from unnest(array[0, 1, 2, 3, 4]) k;
  insert into technician_availability (org_id, technician_id, date, status) values (v_org, v_t1, v_from + 7, 'leave'), (v_org, v_t1, v_from + 8, 'leave');
  insert into attendance (org_id, technician_id, date, check_in_at) values (v_org, v_t1, v_from + 8, now());   -- present AND leave: counted once
  insert into org_holidays (org_id, holiday_date, name) values (v_org, v_from + 9, '__TEST_ holiday');
  -- a Sunday attendance must not change the working-day arithmetic
  insert into attendance (org_id, technician_id, date, check_in_at) values (v_org, v_t1, v_from + 6, now());

  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  -- working days: 12 (Mon..Sat x2) minus 1 holiday = 11; covered = present(0..4 and 8) + leave(7, 8) = {0,1,2,3,4,7,8} = 7 days
  perform pg_temp.chk('working days = Monday to Saturday minus holidays', r.working_days = 11 and r.holidays = 1, r.working_days::text || '/' || r.holidays::text);
  perform pg_temp.chk('present and leave are counted on working days; a Sunday check-in is ignored',
    r.present_days = 6 and r.leave_days = 2, r.present_days::text || '/' || r.leave_days::text);
  perform pg_temp.chk('absent = working days - days present or on leave (a day both present and on leave counts once)',
    r.absent_days = 11 - 7, r.absent_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a technician with no attendance is absent on every working day', r.absent_days = 11 and r.present_days = 0 and r.leave_days = 0, r.absent_days::text);

  -- future days are not counted as absent; a technician created mid-window counts from that day
  update technicians set created_at = ((v_from + 3)::timestamp at time zone 'Asia/Kolkata') where id = v_t2;
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('days before the technician record existed are not counted', r.working_days = 11 - 3, r.working_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today, v_today + 30) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('today and future dates are never counted (completed days only)',
    r.working_days = 0, r.working_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today, v_today) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a window that is only today has no working days and no absent days', r.working_days = 0 and r.absent_days = 0, r.working_days::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 1, v_today) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('yesterday counts when it is a working day, today does not',
    r.working_days = (case when extract(isodow from v_today - 1) between 1 and 6 then 1 else 0 end), r.working_days::text);

  -- ---------- revenue and jobs ----------
  v_vis := pg_temp.job(v_org, v_c, v_t1, 1000, v_from + 1);
  perform pg_temp.job(v_org, v_c, v_t1, 2500, v_from + 2);
  perform pg_temp.job(v_org, v_ctest, v_t1, 9999, v_from + 2);                 -- flagged test customer: left out
  perform pg_temp.job(v_org, v_c, v_t2, 400, v_from + 3);
  perform pg_temp.job(v_org, v_c, v_t1, 777, v_from - 20);                      -- outside the period
  -- a completed job with no invoice counts as a job, adds no revenue
  insert into service_tickets (org_id, customer_id, type, name_of_complaint) values (v_org, v_c, 'paid', '__TEST_ no invoice')
    returning id into v_inv;
  insert into service_visits (org_id, ticket_id, technician_id, timer_start, timer_end)
    values (v_org, v_inv, v_t1, ((v_from + 4)::timestamp + interval '9 hours') at time zone 'Asia/Kolkata', ((v_from + 4)::timestamp + interval '10 hours') at time zone 'Asia/Kolkata');
  update service_tickets set status = 'completed' where id = v_inv;
  insert into ratings (org_id, visit_id, stars) values (v_org, v_vis, 4);

  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('revenue = invoice totals of completed jobs in the period (test customers and other periods left out)',
    r.revenue = 3500 and r.jobs_completed = 3 and r.jobs_invoiced = 2, r.revenue::text || '/' || r.jobs_completed::text || '/' || r.jobs_invoiced::text);
  perform pg_temp.chk('average call value = revenue / invoiced jobs', r.avg_call_value = 1750.00, coalesce(r.avg_call_value::text, 'null'));
  perform pg_temp.chk('customer-app rating average is shown (not a Google review)', r.avg_rating = 4.00 and r.rating_count = 1, coalesce(r.avg_rating::text, 'null'));
  -- an open (not completed) job adds nothing
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_c, 'spare', 50, 50, 'due') returning id into v_inv;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, invoice_id) values (v_org, v_c, 'paid', '__TEST_ open', v_inv);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('a ticket that is not completed adds no revenue', r.revenue = 3500);

  -- ---------- what is a real sale: no void state exists; a ticket that is not completed is not one ----------
  perform pg_temp.chk('the schema has no void / cancelled / draft invoice state (payment_status is paid | partial | due only)',
    (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = 'public.payment_status'::regtype) = array['paid', 'partial', 'due']
    and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices'
                      and (column_name ilike '%void%' or column_name ilike '%cancel%' or column_name = 'status' or column_name ilike '%draft%')),
    'if this fails a new invoice state exists: revisit report_technician_table');
  -- a DUE (unpaid) completed job is still revenue
  v_vis := pg_temp.job(v_org, v_c, v_t2, 300, v_from + 5);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_from, v_to) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an unpaid (due) invoice of a completed job counts as revenue', r.revenue >= 300 + 400, r.revenue::text);

  -- ---------- referral revenue: forward-only stamp ----------
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_cref, '__TEST_ referral', 'referral', 'won', v_t1);
  v_inv := null;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 8000, 8000, 'paid') returning id into v_inv;
  perform pg_temp.chk('an invoice for a customer with a technician-referral lead is stamped at insert',
    (select referred_by_technician_id from invoices where id = v_inv) = v_t1);
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'amc', 3000, 3000, 'paid');
  perform pg_temp.job(v_org, v_cref, v_t2, 600, v_today - 1, 'spare');
  perform pg_temp.chk('an invoice for a customer with no referral lead is not stamped',
    (select referred_by_technician_id is null from invoices where customer_id = v_c and org_id = v_org limit 1));
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 2, v_today + 1) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('referral revenue is split for the referrer: sales 8000, AMC 3000, service 600 (the stamped service invoice)',
    r.referral_sales = 8000 and r.referral_amc = 3000 and r.referral_service = 600 and r.referral_total = 11600,
    r.referral_sales::text || '/' || r.referral_amc::text || '/' || r.referral_service::text);
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 2, v_today + 1) where technician_id = v_t2;
  perform pg_temp.as_pg();
  perform pg_temp.chk('the technician who did the referred service job gets the job revenue, not the referral revenue',
    r.referral_total = 0 and r.revenue >= 600, r.referral_total::text || '/' || r.revenue::text);

  -- an invoice whose ticket was CANCELLED is not a real sale: left out of the referral sums (and never in revenue)
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_cref, '__TEST_ referral again', 'referral', 'won', v_t1);
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'spare', 4000, 4000, 'due') returning id into v_inv;
  insert into service_tickets (org_id, customer_id, type, name_of_complaint, invoice_id, status) values (v_org, v_cref, 'paid', '__TEST_ cancelled', v_inv, 'cancelled');
  perform pg_temp.as_user(v_ops);
  select * into r from report_technician_table(v_today - 2, v_today + 1) where technician_id = v_t1;
  perform pg_temp.as_pg();
  perform pg_temp.chk('an invoice of a cancelled ticket is stamped but not counted in referral revenue',
    (select referred_by_technician_id from invoices where id = v_inv) = v_t1 and r.referral_service = 600 and r.referral_total = 11600,
    r.referral_service::text || '/' || r.referral_total::text);

  -- 30-day window and lost leads
  update leads set created_at = now() - interval '45 days' where org_id = v_org and customer_id = v_cref;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 5, 5, 'paid') returning id into v_inv;
  perform pg_temp.chk('a referral lead older than 30 days does not stamp', (select referred_by_technician_id is null from invoices where id = v_inv));
  update leads set created_at = now() - interval '2 days', status = 'lost' where org_id = v_org and customer_id = v_cref;
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_cref, 'product', 6, 6, 'paid') returning id into v_inv;
  perform pg_temp.chk('a lost referral lead does not stamp', (select referred_by_technician_id is null from invoices where id = v_inv));

  -- forward-only: a referral lead created AFTER an invoice never stamps that invoice
  insert into invoices (org_id, customer_id, type, subtotal, total, payment_status) values (v_org, v_c, 'product', 11, 11, 'paid') returning id into v_inv;
  insert into leads (org_id, customer_id, name, source, status, owner_id) values (v_org, v_c, '__TEST_ late referral', 'referral', 'won', v_t2);
  update invoices set total = total where id = v_inv;
  perform pg_temp.chk('nothing back-fills: the earlier invoice stays unstamped after the referral lead appears and the invoice is updated',
    (select referred_by_technician_id is null from invoices where id = v_inv));

  -- ---------- roles and org scope ----------
  perform pg_temp.as_user(v_sales);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('sales_admin cannot read the technician table', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_cr);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('a customer-role user cannot read it', s like '%not permitted%', coalesce(s, 'accepted'));
  perform pg_temp.as_anon();
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_from, v_to));
  perform pg_temp.chk('anon cannot call it', s like '%permission denied%', coalesce(s, 'accepted'));
  perform pg_temp.as_user(v_master2);
  select count(*) into n from report_technician_table(v_from, v_to) where technician_id in (v_t1, v_t2);
  perform pg_temp.as_pg();
  perform pg_temp.chk('another organisation''s master sees none of these technicians', n = 0, n::text);
  perform pg_temp.as_user(v_ops);
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_to, v_from));
  perform pg_temp.chk('a reversed range is refused', s like '%invalid date range%', coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$select * from report_technician_table(%L, %L)$q$, v_today - 400, v_today));
  perform pg_temp.chk('a range over 366 days is refused', s like '%limited to 366%', coalesce(s, 'accepted'));
  perform pg_temp.as_pg();

  -- ---------- holidays: master writes, staff read ----------
  perform pg_temp.as_user(v_master);
  insert into org_holidays (org_id, holiday_date, name) values (v_org, v_from + 10, '__TEST_ second holiday');
  perform pg_temp.as_user(v_ops);
  select count(*) into n from org_holidays;
  s := pg_temp.raises(format($q$insert into org_holidays (org_id, holiday_date, name) values (%L, %L, 'x')$q$, v_org, v_from + 11));
  perform pg_temp.as_pg();
  perform pg_temp.chk('operations can read holidays (2) but not write them', n = 2 and s is not null, n::text || ' / ' || coalesce(s, 'accepted'));
  s := pg_temp.raises(format($q$insert into org_holidays (org_id, holiday_date, name) values (%L, %L, 'dup')$q$, v_org, v_from + 10));
  perform pg_temp.chk('one holiday per date', s like '%duplicate key%', coalesce(s, 'accepted'));

  raise exception 'RESULTS%', E'\n' || (select string_agg(r2.line, E'\n' order by r2.n) from pg_temp.res r2);
end $t$;
$rh1$;
  v_hash := encode(sha256(convert_to(v_text, 'UTF8')), 'hex');
  if v_hash <> 'c6e9aefc559365a8774216b831029e868f2fc6e808639233c272bf56c6925a4d' then
    raise exception 'REHEARSAL_REFUSED: hash mismatch for technician_table.test.sql: %', v_hash;
  end if;
  execute v_text;

  raise exception 'REHEARSAL_DID_NOT_RAISE: the test file should have raised RESULTS';
end
$rehearsal$;
