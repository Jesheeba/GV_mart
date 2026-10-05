-- Phase 1, commit 5: give every OPEN lead that has no follow-up an "Initial
-- call" task, spread over the next working days (max 25 a day) so the team
-- is not handed the whole backlog at once.
--
--   * Starts on the first working day AFTER today (IST), per Mon–Sat settings.
--   * Leads are taken oldest first. 3 working days unless that would exceed
--     25/day (then more days are used).
--   * Within a day the tasks are spread evenly between opening + 30 min
--     (10:00 by default) and 1 hour before closing (18:00), on 5-minute marks.
--   * created_by is null => shown as "System" in the timeline.
--
-- Idempotent: a lead that already has an open follow-up (including one created
-- by the new-lead trigger) is skipped, so re-running adds nothing.

do $$
declare
  v_org record;
  v_start_day date;
  v_s record;
  v_open time;
  v_close time;
  v_n integer;
  v_per_day integer;
  v_created integer;
begin
  for v_org in select id from public.organizations loop
    select * into v_s from public.settings where org_id = v_org.id;
    v_open := coalesce(v_s.lead_work_start, '09:30') + interval '30 minutes';
    v_close := coalesce(v_s.lead_work_end, '19:00') - interval '1 hour';
    v_start_day := public.lead_next_working_day(v_org.id, public._lead_ist_date(now()));

    select count(*) into v_n
    from public.leads l
    where l.org_id = v_org.id and l.status not in ('won', 'lost')
      and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open');

    if v_n = 0 then
      continue;
    end if;

    -- 3 working days, but never more than 25 a day.
    v_per_day := least(25, ceil(v_n / 3.0)::int);

    with todo as (
      select l.id, row_number() over (order by l.created_at, l.id) as rn
      from public.leads l
      where l.org_id = v_org.id and l.status not in ('won', 'lost')
        and not exists (select 1 from public.lead_followups f where f.lead_id = l.id and f.status = 'open')
    ),
    working_days as (
      select d::date as day, row_number() over (order by d) as k
      from generate_series(v_start_day::timestamp, (v_start_day + 120)::timestamp, interval '1 day') d
      where public._lead_is_working_day(v_org.id, d::date)
    ),
    slotted as (
      select
        t.id,
        wd.day,
        ((t.rn - 1) % v_per_day) as pos,
        least(v_per_day, v_n - ((t.rn - 1) / v_per_day) * v_per_day) as cnt_in_day
      from todo t
      join working_days wd on wd.k = ((t.rn - 1) / v_per_day) + 1
    )
    insert into public.lead_followups (org_id, lead_id, due_at, type, note, source)
    select
      v_org.id, s.id,
      public._lead_ist_ts(
        s.day,
        v_open + make_interval(mins => (floor((s.pos * (extract(epoch from (v_close - v_open)) / 60.0 / s.cnt_in_day)) / 5) * 5)::int)
      ),
      'call', 'Initial call', 'initial_call'
    from slotted s;

    get diagnostics v_created = row_count;
    raise notice 'lead backfill: org % -> % initial calls (max % per day) starting %', v_org.id, v_created, v_per_day, v_start_day;
  end loop;
end
$$;
