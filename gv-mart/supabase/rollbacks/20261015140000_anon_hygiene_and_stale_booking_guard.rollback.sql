-- Rollback for 20261015140000_anon_hygiene_and_stale_booking_guard.sql. Previous ACLs:
-- Desktop\GV_mart_acl_backup_2026-10-12_anon_hygiene_batch2.json (the three pure helpers had explicit anon/authenticated
-- grants plus PUBLIC; the others PUBLIC only; technician_installation_count also had an explicit authenticated grant).
do $rb$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('wa_get_business_info', 'wa_get_emi_info', 'wa_get_products_by_category',
                         'wa_supplier_latest_sent_po', 'technician_installation_count',
                         '_next_ticket_available_for_technician', '_customer_exemption_blocks',
                         '_derive_payment_status', '_largest_free_window')
  loop
    if r.proname in ('_customer_exemption_blocks', '_derive_payment_status', '_largest_free_window') then
      execute format('grant execute on function %s to public, anon, authenticated', r.sig);
    elsif r.proname = 'technician_installation_count' then
      execute format('grant execute on function %s to public, authenticated', r.sig);
    else
      execute format('grant execute on function %s to public', r.sig);
    end if;
  end loop;
end
$rb$;

-- resolve_stale_bookings: the exact pre-change body (organisation match only)
create or replace function public.resolve_stale_bookings(p_org_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_local timestamp;
  v_work_end time;
  v_count integer := 0;
  v_appt record;
begin
  if p_org_id is distinct from public.current_org_id() then
    raise exception 'resolve_stale_bookings: org mismatch';
  end if;

  v_now_local := now() at time zone 'Asia/Kolkata';
  select work_end into v_work_end from public.settings where org_id = p_org_id;

  for v_appt in
    select a.id as appointment_id, a.ticket_id
    from public.appointments a
    join public.service_tickets st on st.id = a.ticket_id
    left join public.appointment_slots s on s.id = a.slot_id
    where a.org_id = p_org_id
      and a.follow_up_flagged_at is null
      and a.technician_id is null
      and a.status = 'scheduled'
      and st.status = 'open'
      and (
        (a.scheduled_at at time zone 'Asia/Kolkata')::date < v_now_local::date
        or (
          (a.scheduled_at at time zone 'Asia/Kolkata')::date = v_now_local::date
          and v_now_local::time > coalesce(s.end_time, a.available_to, v_work_end)
        )
      )
  loop
    update public.appointments set follow_up_flagged_at = now() where id = v_appt.appointment_id;

    insert into public.notifications (org_id, role, type, title, body, ref_id)
    select p_org_id, r, 'booking_needs_followup', 'Booking needs manual follow-up',
      format('Ticket %s was not assigned a technician today — call the customer to confirm a priority slot.', v_appt.ticket_id),
      v_appt.ticket_id
    from unnest(array['master', 'operation_admin', 'sales_admin']::user_role[]) as r;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
