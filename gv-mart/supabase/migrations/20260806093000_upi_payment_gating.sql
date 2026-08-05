-- QR Payment + Gated Completion Code — the payment-collection RPCs, plus
-- gating the existing completion-code flow (generate_visit_otp/
-- verify_visit_otp, 20260725110000_otp_completion_confirmation.sql) on
-- payment being confirmed first. The completion-code mechanism itself is
-- reused unchanged — this only adds a precondition check to it.

-- ── get_visit_payment_state: read-only, technician-scoped ──────────────────
-- Technicians have no direct SELECT policy on `invoices` (only
-- invoices_select_staff / the customer's own-row policy) — this is how the
-- Payment step learns the invoice's current payment_method/payment_status/
-- total. A live round-trip (not queued), same "never trust stale/client
-- state" posture as generate_visit_otp/verify_visit_otp.
create or replace function public.get_visit_payment_state(
  p_org_id uuid,
  p_visit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_invoice invoices;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'get_visit_payment_state: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'get_visit_payment_state: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'get_visit_payment_state: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'get_visit_payment_state: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select i.* into v_invoice
  from public.service_tickets t join public.invoices i on i.id = t.invoice_id
  where t.id = v_visit.ticket_id;

  if v_invoice.id is null then
    return jsonb_build_object('invoice_found', false);
  end if;

  return jsonb_build_object(
    'invoice_found', true,
    'invoice_id', v_invoice.id,
    'payment_method', v_invoice.payment_method,
    'payment_status', v_invoice.payment_status,
    'total', v_invoice.total
  );
end;
$$;

grant execute on function public.get_visit_payment_state(uuid, uuid) to authenticated;

-- ── record_upi_payment: technician-confirmed manual UPI collection ─────────
-- The technician is on-site with the customer at the Payment step and can
-- see the UPI app's own success screen — this is the one action that turns
-- that into a server-recorded fact. Idempotent (a re-tap after a flaky
-- connection succeeded server-side is a no-op, not an error).
create or replace function public.record_upi_payment(
  p_org_id uuid,
  p_visit_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_invoice invoices;
  v_now timestamptz := now();
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'record_upi_payment: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'record_upi_payment: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'record_upi_payment: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'record_upi_payment: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select i.* into v_invoice
  from public.service_tickets t join public.invoices i on i.id = t.invoice_id
  where t.id = v_visit.ticket_id;

  if v_invoice.id is null then
    -- Distinct, catchable error: create_service_invoice was queued through
    -- the technician's offline outbox (services/technician.ts) and hasn't
    -- synced yet. The frontend surfaces this as "still syncing your
    -- invoice, try again shortly" rather than a generic failure.
    raise exception 'record_upi_payment: invoice_pending — invoice for visit % has not synced yet', p_visit_id;
  end if;
  if v_invoice.payment_method is distinct from 'upi' then
    raise exception 'record_upi_payment: invoice % was not created with payment_method=upi', v_invoice.id;
  end if;

  if v_invoice.payment_status = 'paid' then
    return jsonb_build_object('ok', true, 'invoice_id', v_invoice.id, 'total', v_invoice.total, 'already_paid', true);
  end if;

  insert into public.payments (org_id, invoice_id, visit_id, amount, payment_method, payment_status, paid_at, confirmed_by)
  values (p_org_id, v_invoice.id, p_visit_id, v_invoice.total, 'upi', 'paid', v_now, auth.uid());

  update public.invoices
    set amount_paid = total, payment_status = 'paid'
    where id = v_invoice.id;

  return jsonb_build_object('ok', true, 'invoice_id', v_invoice.id, 'total', v_invoice.total, 'already_paid', false);
end;
$$;

grant execute on function public.record_upi_payment(uuid, uuid) to authenticated;

-- ── generate_visit_otp: add the payment gate ────────────────────────────────
-- Only change from 20260725110000's version: block minting a code for a
-- visit whose invoice is a confirmed-unpaid UPI invoice. Fails OPEN when the
-- invoice can't be resolved yet (still mid-outbox-sync) so this can never
-- newly block a cash/transfer visit — the unconditional backstop is
-- verify_visit_otp below, which is what actually closes the visit.
create or replace function public.generate_visit_otp(
  p_org_id uuid,
  p_visit_id uuid,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_existing service_visit_otps;
  v_payment_method payment_method;
  v_payment_status payment_status;
  v_code text;
  v_now timestamptz := now();
  v_expires timestamptz;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'generate_visit_otp: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'generate_visit_otp: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit.id is null then
    raise exception 'generate_visit_otp: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'generate_visit_otp: visit % does not belong to the calling technician', p_visit_id;
  end if;
  if v_visit.timer_end is not null then
    raise exception 'generate_visit_otp: visit % is already closed', p_visit_id;
  end if;

  select i.payment_method, i.payment_status into v_payment_method, v_payment_status
  from public.service_tickets t join public.invoices i on i.id = t.invoice_id
  where t.id = v_visit.ticket_id;

  if v_payment_method = 'upi' and v_payment_status is distinct from 'paid' then
    raise exception 'generate_visit_otp: payment_pending — UPI payment has not been confirmed for visit %', p_visit_id;
  end if;

  select * into v_existing from public.service_visit_otps where visit_id = p_visit_id;

  if not p_force and v_existing.id is not null and v_existing.verified_at is null and v_existing.bypassed_at is null
     and v_existing.expires_at > v_now and v_existing.attempts < v_existing.max_attempts then
    return jsonb_build_object('generated_at', v_existing.generated_at, 'expires_at', v_existing.expires_at, 'reused', true);
  end if;

  v_code := lpad(floor(random() * 10000)::int::text, 4, '0');
  v_expires := v_now + interval '15 minutes';

  insert into public.service_visit_otps (org_id, visit_id, code, generated_at, expires_at, attempts, verified_at, bypassed_by, bypassed_reason, bypassed_at)
  values (p_org_id, p_visit_id, v_code, v_now, v_expires, 0, null, null, null, null)
  on conflict (visit_id) do update set
    org_id = excluded.org_id,
    code = excluded.code,
    generated_at = excluded.generated_at,
    expires_at = excluded.expires_at,
    attempts = 0,
    verified_at = null,
    bypassed_by = null,
    bypassed_reason = null,
    bypassed_at = null;

  return jsonb_build_object('generated_at', v_now, 'expires_at', v_expires, 'reused', false);
end;
$$;

-- ── verify_visit_otp: add the same payment gate (the real backstop) ────────
-- This is the function that actually closes the visit (timer_end) — the
-- payment_pending check here is unconditional (no fail-open), since by the
-- time the technician reaches Verify, the invoice has necessarily existed
-- for a while (Signatures + the Payment step's "Payment received" tap
-- already happened), and closing the visit is exactly the "job truly
-- closed" moment the payment gate exists to protect.
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
  v_payment_method payment_method;
  v_payment_status payment_status;
  v_now timestamptz := now();
  v_remaining integer;
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
      set timer_end = v_now, notes = coalesce(nullif(btrim(p_notes), ''), notes), otp_verified = true
      where id = p_visit_id;
    return jsonb_build_object('ok', true, 'visit_id', p_visit_id, 'timer_end', v_now);
  end if;

  update public.service_visit_otps set attempts = attempts + 1, last_attempt_at = v_now where id = v_otp.id
  returning (max_attempts - attempts) into v_remaining;

  return jsonb_build_object('ok', false, 'reason', 'incorrect', 'remaining_attempts', greatest(v_remaining, 0));
end;
$$;

-- admin_override_visit_completion is deliberately left untouched — it must
-- still be able to bypass a stuck UPI payment (e.g. the customer paid by
-- handing over cash instead at the last second), so no payment gate is
-- added there.
