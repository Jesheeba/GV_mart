-- Technician Module Audit, Task 3: technicians must never be blocked from
-- completing a job after exceeding its estimated duration (confirmed: no
-- such blocking logic exists anywhere today — job-overrun.ts and the SOP
-- step/advance gates are already display-only). What's genuinely missing is
-- a persisted record of the delay + an admin notification when it happens;
-- the live overrun badge on the admin ticket detail page already covers
-- "visible in reports/dashboard" for the per-visit figure, so this migration
-- only adds the notification, at the two places a visit's timer_end is ever
-- set (verify_visit_otp for a real customer-confirmed completion,
-- admin_override_visit_completion for the OTP bypass safety valve) — both
-- live, unchanged otherwise, in 20260725110000_otp_completion_confirmation.sql.
--
-- Delay = actual minutes (timer_end - timer_start) exceeding
-- service_tickets.estimated_duration_minutes. Deliberately NOT reproducing
-- the client's fuller computeTicketAllowedDuration (job-allowance.ts, which
-- also folds in review/enquiry-time admin settings) server-side — that would
-- duplicate non-trivial, changeable business logic in SQL and risk drifting
-- out of sync. The ticket's own stored estimate is the right root-level
-- source of truth for "was this job late," matching job-overrun.ts's own
-- rule of never flagging a delay when there's nothing valid to compare
-- against (estimated_duration_minutes null -> no notification).

create or replace function public.verify_visit_otp(
  p_org_id uuid,
  p_visit_id uuid,
  p_code text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_otp service_visit_otps;
  v_now timestamptz := now();
  v_remaining integer;
  v_ticket service_tickets;
  v_actual_minutes integer;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'verify_visit_otp: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'verify_visit_otp: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'verify_visit_otp: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'verify_visit_otp: visit % does not belong to the calling technician', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'verify_visit_otp: visit % is already closed', p_visit_id;
  end if;

  select * into v_otp from public.service_visit_otps where visit_id = p_visit_id;
  if v_otp.id is null then
    raise exception 'verify_visit_otp: otp_missing — no code has been generated for visit %', p_visit_id;
  end if;
  if v_otp.bypassed_at is not null then
    raise exception 'verify_visit_otp: otp_bypassed — visit % was already completed via admin override', p_visit_id;
  end if;
  if v_otp.expires_at <= v_now then
    raise exception 'verify_visit_otp: otp_expired — the code for visit % has expired', p_visit_id;
  end if;
  if v_otp.attempts >= v_otp.max_attempts then
    raise exception 'verify_visit_otp: otp_locked — too many incorrect attempts for visit %', p_visit_id;
  end if;

  if v_otp.code is not null and btrim(p_code) = v_otp.code then
    update public.service_visit_otps set verified_at = v_now where id = v_otp.id;
    -- The actual completion transition — timer_end only ever closes here or
    -- in admin_override_visit_completion below, never from a queued client
    -- patch anymore (see design decision #2/#6 in the OTP migration header).
    update public.service_visits
      set timer_end = v_now, notes = coalesce(nullif(btrim(p_notes), ''), notes), otp_verified = true
      where id = p_visit_id;

    select * into v_ticket from public.service_tickets where id = v_visit.ticket_id;
    if v_ticket.estimated_duration_minutes is not null and v_visit.timer_start is not null then
      v_actual_minutes := ceil(extract(epoch from (v_now - v_visit.timer_start)) / 60);
      if v_actual_minutes > v_ticket.estimated_duration_minutes then
        insert into public.notifications (org_id, role, type, title, body, ref_id)
        values (
          p_org_id, 'operation_admin', 'service_delay', 'Job ran over estimated time',
          format('Ticket %s took %s min (estimated %s min).', v_visit.ticket_id, v_actual_minutes, v_ticket.estimated_duration_minutes),
          v_visit.ticket_id
        );
      end if;
    end if;

    return jsonb_build_object('ok', true, 'visit_id', p_visit_id, 'timer_end', v_now);
  end if;

  update public.service_visit_otps set attempts = attempts + 1, last_attempt_at = v_now where id = v_otp.id
  returning (max_attempts - attempts) into v_remaining;

  return jsonb_build_object('ok', false, 'reason', 'incorrect', 'remaining_attempts', greatest(v_remaining, 0));
end;
$$;

grant execute on function public.verify_visit_otp(uuid, uuid, text, text) to authenticated;

create or replace function public.admin_override_visit_completion(
  p_org_id uuid,
  p_visit_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_visit service_visits;
  v_now timestamptz := now();
  v_reason text := nullif(btrim(p_reason), '');
  v_ticket service_tickets;
  v_actual_minutes integer;
begin
  if not public.is_ops_staff() then
    raise exception 'admin_override_visit_completion: only master or operation_admin may bypass OTP completion';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'admin_override_visit_completion: org mismatch';
  end if;
  if v_reason is null then
    raise exception 'admin_override_visit_completion: a reason is required';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'admin_override_visit_completion: visit % not found', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'admin_override_visit_completion: visit % is already closed', p_visit_id;
  end if;

  insert into public.service_visit_otps (org_id, visit_id, code, generated_at, expires_at, attempts, bypassed_by, bypassed_reason, bypassed_at)
  values (p_org_id, p_visit_id, null, v_now, v_now, 0, auth.uid(), v_reason, v_now)
  on conflict (visit_id) do update set
    bypassed_by = excluded.bypassed_by,
    bypassed_reason = excluded.bypassed_reason,
    bypassed_at = excluded.bypassed_at;

  update public.service_visits set timer_end = v_now where id = p_visit_id;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id;
  if v_ticket.estimated_duration_minutes is not null and v_visit.timer_start is not null then
    v_actual_minutes := ceil(extract(epoch from (v_now - v_visit.timer_start)) / 60);
    if v_actual_minutes > v_ticket.estimated_duration_minutes then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      values (
        p_org_id, 'operation_admin', 'service_delay', 'Job ran over estimated time (admin override)',
        format('Ticket %s took %s min (estimated %s min), completed via OTP override.', v_visit.ticket_id, v_actual_minutes, v_ticket.estimated_duration_minutes),
        v_visit.ticket_id
      );
    end if;
  end if;

  return jsonb_build_object('ok', true, 'visit_id', p_visit_id, 'timer_end', v_now, 'bypassed', true);
end;
$$;

grant execute on function public.admin_override_visit_completion(uuid, uuid, text) to authenticated;
