-- Shift-end job-assignment prompt (design reviewed + revised per user
-- feedback 2026-08-31 — see chat history for the six-point review that
-- shaped this version). Today, create_service_invoice silently pulls a
-- technician straight into their next waiting job the instant they finish
-- one, via a fire-and-forget `perform` call to
-- _auto_assign_next_ticket_to_technician, with zero regard for the org's
-- configured settings.work_end. This migration gates that: once a
-- technician finishes a job at/after work_end, they're asked to Continue or
-- Check Out instead of being auto-assigned again.
--
-- Only create_service_invoice (the real technician-self-completion path) is
-- touched. complete_appointment (admin manually closing a job from the
-- admin app) has no technician session to prompt, so it keeps its existing
-- unconditional auto-assign, unchanged and untouched by this migration.

alter table public.attendance
  add column shift_end_prompt_pending boolean not null default false;

-- ── Read-only sibling of _auto_assign_next_ticket_to_technician's own
-- eligibility SELECT, WITHOUT its `for update skip locked` — that function's
-- locking behavior is proven and deliberately not touched by this migration.
-- Used only to answer "was there a job this technician could have taken",
-- for the checkout-with-job-waiting admin notification below. ─────────────
create or replace function public._next_ticket_available_for_technician(p_org_id uuid, p_technician_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    join public.technicians t on t.id = p_technician_id
    where a.org_id = p_org_id
      and a.technician_id is null
      and a.status in ('scheduled', 'in_progress')
      and st.status = 'open'
      and (st.product_id is not null or st.unlisted_product_name is not null)
      and (a.scheduled_at is null or a.scheduled_at::date <= current_date)
      and coalesce((
        select sum(st2.estimated_duration_minutes)
        from public.appointments a2
        join public.service_tickets st2 on st2.id = a2.ticket_id
        where a2.technician_id = p_technician_id
          and a2.status in ('scheduled', 'in_progress')
          and a2.scheduled_at::date = coalesce(a.scheduled_at::date, current_date)
      ), 0) + coalesce(st.estimated_duration_minutes, 0) <= t.daily_capacity_minutes
  );
$$;

-- Intentionally NOT granted to authenticated — internal helper, called only
-- from technician_respond_shift_end_prompt below (service_role/SECURITY
-- DEFINER context), same pattern as _auto_assign_next_ticket_to_technician
-- itself.

-- ── create_service_invoice: only the auto-assign-next tail changes. Body is
-- otherwise byte-for-byte the currently-live version (20260805100000). ─────
create or replace function public.create_service_invoice(
  p_org_id uuid,
  p_visit_id uuid,
  p_service_charge numeric,
  p_discount_percent numeric,
  p_spares jsonb,
  p_payment_method payment_method,
  p_txn_id text,
  p_payment_description text,
  p_is_chargeable boolean, -- false for warranty/amc: service_charge forced to 0
  p_amount_paid numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_visit service_visits;
  v_ticket service_tickets;
  v_settings settings;
  v_subtotal numeric(12, 2) := 0;
  v_discount numeric(12, 2);
  v_gst numeric(12, 2);
  v_total numeric(12, 2);
  v_amount_paid numeric(12, 2);
  v_invoice invoices;
  v_item record;
  v_price numeric(12, 2);
  v_cost numeric(12, 2);
  v_line_discount numeric(12, 2);
  v_new_stock integer;
  v_approval_id uuid;
  v_effective_charge numeric(12, 2);
  v_amc_plan_id uuid;
  v_is_spare_covered boolean;
begin
  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'create_service_invoice: caller is not a technician';
  end if;
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'create_service_invoice: org mismatch';
  end if;

  select * into v_visit from public.service_visits where id = p_visit_id and org_id = p_org_id;
  if v_visit is null then
    raise exception 'create_service_invoice: visit % not found', p_visit_id;
  end if;
  if v_visit.technician_id is distinct from v_tech_id then
    raise exception 'create_service_invoice: visit % does not belong to the calling technician', p_visit_id;
  end if;

  select * into v_ticket from public.service_tickets where id = v_visit.ticket_id and org_id = p_org_id;
  if v_ticket is null then
    raise exception 'create_service_invoice: ticket for visit % not found', p_visit_id;
  end if;

  select * into v_settings from public.settings where org_id = p_org_id;
  if v_settings is null then
    raise exception 'create_service_invoice: no settings row for org %', p_org_id;
  end if;

  if p_discount_percent < 0 then
    raise exception 'create_service_invoice: discount cannot be negative';
  end if;
  if p_discount_percent > v_settings.discount_admin_max then
    raise exception 'create_service_invoice: discount % exceeds the admin limit of %', p_discount_percent, v_settings.discount_admin_max;
  end if;

  if p_payment_method = 'transfer'
     and (nullif(p_txn_id, '') is null or nullif(p_payment_description, '') is null) then
    raise exception 'create_service_invoice: bank transfer requires a transaction ID and description';
  end if;

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    select plan_id into v_amc_plan_id from public.amc_contracts where id = v_ticket.contract_id;
  end if;

  v_effective_charge := case when p_is_chargeable then coalesce(p_service_charge, 0) else 0 end;
  v_subtotal := v_effective_charge;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      if v_item.qty is null or v_item.qty <= 0 then
        raise exception 'create_service_invoice: qty must be positive for spare %', v_item.spare_id;
      end if;
      select price into v_price from public.spares where id = v_item.spare_id and org_id = p_org_id;
      if v_price is null then
        raise exception 'create_service_invoice: spare % not found in org %', v_item.spare_id, p_org_id;
      end if;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      if p_is_chargeable or not v_is_spare_covered then
        v_subtotal := v_subtotal + (v_price * v_item.qty);
      end if;
    end loop;
  end if;

  v_discount := round(v_subtotal * p_discount_percent / 100, 2);
  v_gst := round((v_subtotal - v_discount) * v_settings.gst_rate / 100, 2);
  v_total := v_subtotal - v_discount + v_gst;

  v_amount_paid := coalesce(p_amount_paid, v_total);
  if v_amount_paid < 0 then
    raise exception 'create_service_invoice: amount_paid cannot be negative';
  end if;
  if v_amount_paid > v_total then
    raise exception 'create_service_invoice: amount_paid (%) cannot exceed the invoice total (%)', v_amount_paid, v_total;
  end if;

  insert into public.invoices (
    org_id, customer_id, type, subtotal, discount, gst, total,
    payment_method, txn_id, payment_description, payment_status, amount_paid
  ) values (
    p_org_id, v_ticket.customer_id, 'spare', v_subtotal, v_discount, v_gst, v_total,
    p_payment_method, nullif(p_txn_id, ''), nullif(p_payment_description, ''),
    public._derive_payment_status(v_amount_paid, v_total), v_amount_paid
  ) returning * into v_invoice;

  if p_spares is not null and jsonb_array_length(p_spares) > 0 then
    for v_item in select * from jsonb_to_recordset(p_spares) as x(spare_id uuid, qty integer)
    loop
      select price, cost_price into v_price, v_cost from public.spares where id = v_item.spare_id and org_id = p_org_id;
      v_is_spare_covered := v_amc_plan_id is null or exists (
        select 1 from public.amc_plan_covered_spares cs
        where cs.plan_id = v_amc_plan_id and cs.spare_id = v_item.spare_id
      );
      v_price := case when p_is_chargeable or not v_is_spare_covered then v_price else 0 end;
      v_line_discount := round(v_price * v_item.qty * p_discount_percent / 100, 2);

      insert into public.invoice_items (org_id, invoice_id, item_type, item_id, qty, price, discount, cost)
      values (p_org_id, v_invoice.id, 'spare', v_item.spare_id, v_item.qty, v_price, v_line_discount, v_cost);

      insert into public.service_spares_used (org_id, visit_id, spare_id, qty, cost)
      values (p_org_id, p_visit_id, v_item.spare_id, v_item.qty, v_price * v_item.qty);

      update public.inventory
        set stock_qty = stock_qty - v_item.qty
        where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
          and location = 'van' and stock_qty >= v_item.qty
        returning stock_qty into v_new_stock;
      if v_new_stock is null then
        update public.inventory
          set stock_qty = stock_qty - v_item.qty
          where org_id = p_org_id and item_type = 'spare' and item_id = v_item.spare_id
            and location = 'warehouse' and stock_qty >= v_item.qty
          returning stock_qty into v_new_stock;
      end if;
      if v_new_stock is null then
        raise exception 'create_service_invoice: insufficient stock for spare % (need %)', v_item.spare_id, v_item.qty;
      end if;

      insert into public.inventory_movements (org_id, item_type, item_id, change_qty, reason, ref_id)
      values (p_org_id, 'spare', v_item.spare_id, -v_item.qty, 'service_visit', p_visit_id);
    end loop;
  end if;

  update public.service_visits
    set service_charge = v_effective_charge, discount = p_discount_percent
    where id = p_visit_id;

  update public.service_tickets set status = 'completed', invoice_id = v_invoice.id where id = v_ticket.id;
  update public.appointments set status = 'completed'
    where ticket_id = v_ticket.id and technician_id = v_tech_id and status in ('scheduled', 'in_progress');

  if v_ticket.type = 'amc' and v_ticket.contract_id is not null then
    update public.amc_contracts
      set next_service_date = (
        select min(a.scheduled_at::date)
        from public.service_tickets st
        join public.appointments a on a.ticket_id = st.id
        where st.contract_id = v_ticket.contract_id
          and st.type = 'amc'
          and a.status in ('scheduled', 'in_progress')
      )
      where id = v_ticket.contract_id;
  end if;

  if p_discount_percent > v_settings.discount_tech_max then
    insert into public.approvals (org_id, type, ref_id, requested_by, status)
    values (p_org_id, 'discount', v_invoice.id, auth.uid(), 'pending')
    returning id into v_approval_id;
  end if;

  -- This technician's slot just freed up (their appointment flipped to
  -- 'completed' two statements above). Past the org's configured work_end
  -- (IST wall-clock — see 20260731190000_dynamic_attendance_status.sql's
  -- established at-time-zone pattern), don't silently pull them into
  -- another job: flag today's attendance row as awaiting a decision and
  -- notify the technician themselves (shift_end_prompt), same user-targeted
  -- notification shape appointment_assigned already uses. Otherwise,
  -- unchanged existing behavior.
  if (now() at time zone 'Asia/Kolkata')::time >= v_settings.work_end then
    update public.attendance
    set shift_end_prompt_pending = true
    where technician_id = v_tech_id and org_id = p_org_id
      and date = (now() at time zone 'Asia/Kolkata')::date;

    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    select p_org_id, p.id, 'shift_end_prompt', 'Shift end reached',
      format('Your shift ended at %s. Reply to continue or check out.', to_char(v_settings.work_end, 'HH12:MI AM')), v_invoice.id
    from public.technicians t join public.profiles p on p.id = t.profile_id
    where t.id = v_tech_id;
  else
    perform public._auto_assign_next_ticket_to_technician(p_org_id, v_tech_id);
  end if;

  return jsonb_build_object('invoice_id', v_invoice.id, 'total', v_total, 'approval_id', v_approval_id);
end;
$$;

grant execute on function public.create_service_invoice(uuid, uuid, numeric, numeric, jsonb, payment_method, text, text, boolean, numeric) to authenticated;

-- ── technician_respond_shift_end_prompt: the technician's answer to the
-- popup. Atomic claim-and-clear (the UPDATE ... WHERE shift_end_prompt_pending
-- = true ... RETURNING) doubles as both "was this genuinely still pending"
-- and "double-tap/race guard" — a concurrent or stale call simply matches
-- zero rows and gets ok: false, never a second assignment/notification. ───
create or replace function public.technician_respond_shift_end_prompt(p_decision text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tech_id uuid;
  v_org_id uuid;
  v_ist_date date;
  v_attendance_id uuid;
  v_assign_result jsonb;
  v_tech_name text;
  v_job_waiting boolean;
begin
  if p_decision not in ('continue', 'check_out') then
    raise exception 'technician_respond_shift_end_prompt: invalid decision %', p_decision;
  end if;

  v_tech_id := public.current_technician_id();
  if v_tech_id is null then
    raise exception 'technician_respond_shift_end_prompt: caller is not a technician';
  end if;
  v_org_id := public.current_org_id();
  v_ist_date := (now() at time zone 'Asia/Kolkata')::date;

  update public.attendance
  set shift_end_prompt_pending = false
  where technician_id = v_tech_id and org_id = v_org_id and date = v_ist_date
    and shift_end_prompt_pending = true
  returning id into v_attendance_id;

  if v_attendance_id is null then
    return jsonb_build_object('ok', false, 'reason_key', 'technician.shiftEnd.noPendingPrompt');
  end if;

  select p.full_name into v_tech_name
  from public.technicians t join public.profiles p on p.id = t.profile_id
  where t.id = v_tech_id;

  if p_decision = 'continue' then
    v_assign_result := public._auto_assign_next_ticket_to_technician(v_org_id, v_tech_id);

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    select v_org_id, r, 'shift_end_continued', 'Technician working past shift end',
      format('%s chose to continue working past shift end.', coalesce(v_tech_name, 'A technician')), v_attendance_id
    from unnest(array['master', 'operation_admin']::user_role[]) r;

    return jsonb_build_object('ok', true, 'decision', 'continue', 'assigned', v_assign_result);
  else
    v_job_waiting := public._next_ticket_available_for_technician(v_org_id, v_tech_id);
    if v_job_waiting then
      insert into public.notifications (org_id, role, type, title, body, ref_id)
      select v_org_id, r, 'shift_end_checked_out_with_job_waiting', 'Job needs manual assignment',
        format('%s checked out after shift end while a job was waiting.', coalesce(v_tech_name, 'A technician')), v_attendance_id
      from unnest(array['master', 'operation_admin']::user_role[]) r;
    end if;
    return jsonb_build_object('ok', true, 'decision', 'check_out', 'job_was_waiting', v_job_waiting);
  end if;
end;
$$;

grant execute on function public.technician_respond_shift_end_prompt(text) to authenticated;

-- ── Midnight safety net: technician_respond_shift_end_prompt clears the
-- flag on any real answer, so anything still true here means the technician
-- left an earlier day's popup unanswered. Force-closes only those rows
-- (narrow scope, confirmed) so the next check-in starts a clean day. Called
-- by the new technician-shift-reset edge function, same GitHub-Actions-cron
-- pattern as wa-scheduled-tasks. ───────────────────────────────────────────
create or replace function public.reset_stale_shift_end_prompts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  -- (date + time) at time zone 'Asia/Kolkata' is the established pattern for
  -- building a correct timestamptz from IST wall-clock parts (see e.g.
  -- 20260731100000_fix_scheduled_at_timezone.sql) -- a bare `date + time`
  -- would be cast to timestamptz using the DB session's own timezone, which
  -- is exactly the UTC-vs-IST drift this project has been bitten by before.
  update public.attendance
  set check_out_at = coalesce(check_out_at, (date + time '23:59:59') at time zone 'Asia/Kolkata'),
      shift_end_prompt_pending = false
  where shift_end_prompt_pending = true
    and date < (now() at time zone 'Asia/Kolkata')::date;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Intentionally NOT granted to authenticated — service_role only, called
-- from the technician-shift-reset edge function's cron trigger.
