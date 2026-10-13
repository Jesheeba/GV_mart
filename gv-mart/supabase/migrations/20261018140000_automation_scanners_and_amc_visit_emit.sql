-- Automation Phase 3 / Stage B, part 2: SQL scanners (amc.expiring, feedback.requested, review.google_requested) and the
-- AMC visit emit. EVERYTHING HERE ONLY CALLS automation_emit(): rows land as dry-run queue rows. No scanner is scheduled by
-- this migration (callable by service_role / tests with a p_now), nothing is handed over, nothing is sent.
--
--   automation_scan_amc_expiring(p_now, p_windows)   contracts whose expiry_date is exactly 30 / 15 / 7 IST days away
--   automation_scan_feedback(p_now, delay, lookback)  tickets completed (delay .. delay+lookback) hours ago
--   automation_scan_review(p_now, delay, lookback)    same selection, event review.google_requested: EVERY completed service,
--                                                     no rating condition (the 90-day cooldown floor is in the engine)
--   appointments AFTER INSERT trigger                 amc.visit_scheduled when the appointment belongs to an AMC visit ticket
-- Window safety: each emit carries payload.window_end, so a deferred (over the daily cap) message that outlives its window is
-- dropped, never sent late (S5). Idempotency: the engine's key (rule | customer | subject | occurrence | mode), so re-running a
-- scanner adds nothing.

create function public._automation_ist_date(p_ts timestamptz)
returns date language sql immutable as $$ select (p_ts at time zone 'Asia/Kolkata')::date $$;
revoke all on function public._automation_ist_date(timestamptz) from public, anon, authenticated;
grant execute on function public._automation_ist_date(timestamptz) to service_role;

create function public.automation_scan_amc_expiring(p_now timestamptz default now(), p_windows integer[] default array[30, 15, 7])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c       record;
  w       integer;
  v_today date := public._automation_ist_date(p_now);
  v_n     integer := 0;
  v_end   timestamptz;
begin
  foreach w in array p_windows loop
    v_end := ((v_today + 1) + '00:00'::time) at time zone 'Asia/Kolkata';   -- the reminder is only meaningful that day
    for c in
      select ac.id, ac.org_id, ac.customer_id, ac.product_id, ac.plan_id, ac.expiry_date
        from public.amc_contracts ac
       where ac.expiry_date = v_today + w
         and ac.cancelled_at is null
         and ac.status in ('active', 'due_soon')
    loop
      perform public.automation_emit(c.org_id, 'amc.expiring', 'amc_contract', c.id, c.customer_id, 'expiring@' || w,
        jsonb_build_object('days_left', w, 'expiry_date', c.expiry_date::text, 'product_id', c.product_id, 'plan_id', c.plan_id,
                           'window_end', v_end::text));
      v_n := v_n + 1;
    end loop;
  end loop;
  return jsonb_build_object('emitted', v_n, 'windows', to_jsonb(p_windows), 'ist_date', v_today);
end;
$$;
revoke all on function public.automation_scan_amc_expiring(timestamptz, integer[]) from public, anon, authenticated;
grant execute on function public.automation_scan_amc_expiring(timestamptz, integer[]) to service_role;

-- completed tickets in a time window: completion time = the last visit's timer_end, else the ticket's updated_at
create function public._automation_completed_tickets(p_now timestamptz, p_delay_hours integer, p_lookback_hours integer)
returns table (org_id uuid, ticket_id uuid, customer_id uuid, ticket_type text, completed_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select t.org_id, t.id, t.customer_id, t.type::text, x.done
    from public.service_tickets t
    cross join lateral (
      select coalesce((select max(v.timer_end) from public.service_visits v where v.ticket_id = t.id), t.updated_at) as done
    ) x
   where t.status = 'completed'
     and x.done <= p_now - (p_delay_hours * interval '1 hour')
     and x.done >  p_now - ((p_delay_hours + p_lookback_hours) * interval '1 hour')
$$;
revoke all on function public._automation_completed_tickets(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public._automation_completed_tickets(timestamptz, integer, integer) to service_role;

create function public.automation_scan_feedback(p_now timestamptz default now(), p_delay_hours integer default 24, p_lookback_hours integer default 72)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record; v_n integer := 0;
begin
  for t in select * from public._automation_completed_tickets(p_now, p_delay_hours, p_lookback_hours) loop
    perform public.automation_emit(t.org_id, 'feedback.requested', 'ticket', t.ticket_id, t.customer_id, 'feedback',
      jsonb_build_object('ticket_type', t.ticket_type,
                         'window_end', (t.completed_at + ((p_delay_hours + p_lookback_hours) * interval '1 hour'))::text));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('emitted', v_n);
end;
$$;
revoke all on function public.automation_scan_feedback(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.automation_scan_feedback(timestamptz, integer, integer) to service_role;

create function public.automation_scan_review(p_now timestamptz default now(), p_delay_hours integer default 24, p_lookback_hours integer default 72)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  t record; v_n integer := 0;
begin
  -- Every completed service, whatever the rating: no rating, satisfaction or staff condition exists here (Google policy).
  for t in select * from public._automation_completed_tickets(p_now, p_delay_hours, p_lookback_hours) loop
    perform public.automation_emit(t.org_id, 'review.google_requested', 'ticket', t.ticket_id, t.customer_id, 'review',
      jsonb_build_object('ticket_type', t.ticket_type,
                         'window_end', (t.completed_at + ((p_delay_hours + p_lookback_hours) * interval '1 hour'))::text));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('emitted', v_n);
end;
$$;
revoke all on function public.automation_scan_review(timestamptz, integer, integer) from public, anon, authenticated;
grant execute on function public.automation_scan_review(timestamptz, integer, integer) to service_role;

-- AMC visit scheduled: the appointment of a visit ticket that belongs to an AMC contract. Additive trigger (no live function
-- body replaced); failures are logged to automation_errors and never block the appointment write.
create function public._trg_automation_emit_amc_visit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
begin
  begin
    select st.id, st.org_id, st.customer_id, st.contract_id, st.product_id into t
      from public.service_tickets st where st.id = new.ticket_id;
    if t.contract_id is not null and new.scheduled_at is not null then
      perform public.automation_emit(t.org_id, 'amc.visit_scheduled', 'amc_contract', t.contract_id, t.customer_id,
        'visit@' || t.id::text,
        jsonb_build_object('visit_date', public._automation_ist_date(new.scheduled_at)::text,
                           'days_left', greatest(public._automation_ist_date(new.scheduled_at) - public._automation_ist_date(now()), 0),
                           'product_id', t.product_id, 'technician_id', new.technician_id));
    end if;
  exception when others then
    perform public._automation_log_error(new.org_id, tg_table_name || ':' || tg_op, 'amc.visit_scheduled', 'amc_contract', new.id, sqlstate, sqlerrm);
  end;
  return null;
end;
$$;
revoke all on function public._trg_automation_emit_amc_visit() from public, anon, authenticated;
create trigger zz_automation_emit_amc_visit after insert on public.appointments
  for each row execute function public._trg_automation_emit_amc_visit();

-- the catalogue now says these events have an emitter
update public.automation_events set has_emitter = true
 where event_key in ('amc.expiring', 'feedback.requested', 'review.google_requested', 'amc.visit_scheduled');
