-- Parallel-migration collision fix (see memory: gv_mart_parallel_migration_
-- collisions). 20260807120000_visit_actual_duration.sql landed on the live
-- DB with `verify_visit_otp(uuid, uuid, text, text)` — the OLD 4-arg
-- signature, based on a version of this function from BEFORE both the UPI
-- payment gate (20260806093000_upi_payment_gating.sql) and the mandatory
-- enquiry-confirmation param (20260807091000_mandatory_enquiry_confirmation.
-- sql, this session's Task 5). Because the new migration didn't drop the
-- existing 5-arg overload first, Postgres now has BOTH functions live:
-- calls from this session's frontend (5 named args, including
-- p_enquiry_generated) still hit the right one and never ran the actual-
-- duration/completed-late logic; a call with only 4 args would hit the
-- other one and skip both the UPI gate and the mandatory enquiry
-- confirmation entirely. This migration merges all three generations into
-- one 5-arg function and drops the stray 4-arg overload so there is exactly
-- one `verify_visit_otp` again.
drop function if exists public.verify_visit_otp(uuid, uuid, text, text);
drop function if exists public.verify_visit_otp(uuid, uuid, text, boolean, text);

create or replace function public.verify_visit_otp(
  p_org_id uuid,
  p_visit_id uuid,
  p_code text,
  p_enquiry_generated boolean,
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
  v_payment_method payment_method;
  v_payment_status payment_status;
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
  if p_enquiry_generated is null then
    raise exception 'verify_visit_otp: enquiry_confirmation_required — whether a new enquiry was generated must be answered before completing visit %', p_visit_id;
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

  select i.payment_method, i.payment_status into v_payment_method, v_payment_status
  from public.service_tickets t join public.invoices i on i.id = t.invoice_id
  where t.id = v_visit.ticket_id;

  if v_payment_method = 'upi' and v_payment_status is distinct from 'paid' then
    raise exception 'verify_visit_otp: payment_pending — UPI payment has not been confirmed for visit %', p_visit_id;
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
    update public.service_visits
      set timer_end = v_now, notes = coalesce(nullif(btrim(p_notes), ''), notes), otp_verified = true, enquiry_generated = p_enquiry_generated
      where id = p_visit_id;

    select * into v_ticket from public.service_tickets where id = v_visit.ticket_id;
    if v_visit.timer_start is not null then
      v_actual_minutes := ceil(extract(epoch from (v_now - v_visit.timer_start)) / 60);
      update public.service_visits
        set actual_duration_minutes = v_actual_minutes,
            completed_late = case when v_ticket.estimated_duration_minutes is not null
                                   then v_actual_minutes > v_ticket.estimated_duration_minutes
                                   else null end
        where id = p_visit_id;

      if v_ticket.estimated_duration_minutes is not null and v_actual_minutes > v_ticket.estimated_duration_minutes then
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

grant execute on function public.verify_visit_otp(uuid, uuid, text, boolean, text) to authenticated;
