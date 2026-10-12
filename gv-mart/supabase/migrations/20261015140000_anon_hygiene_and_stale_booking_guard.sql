-- Batch 2 of the 2026-10-12 anon-executable function review (docs/anon-executable-functions-2026-10-12.md, groups C and D).
-- HELD: not applied until approved.
--
-- 1. resolve_stale_bookings: until now only an organisation match. Its caller is the customer dashboard (resolve-on-view,
--    src/services/customerApp.ts), so customers must keep working; it also had no service_role path (auth.uid() is NULL there,
--    so the organisation match always failed). The sweep itself is unchanged (it is organisation-wide and idempotent: an
--    appointment is flagged once). New guard, evaluated before anything else: the caller must be
--      - a customer of the organisation, or
--      - an active technician of the organisation, or
--      - active office staff (is_staff() is false for an inactive master / operation_admin / sales_admin after F-07), or
--      - the service role (an Edge Function / job passing p_org_id).
--    Everyone else (a signed-in user with no profile, an inactive staff member, a profile of another kind) is refused.
-- 2. Revoke the nine read-only / helper functions from PUBLIC, anon and authenticated; service_role keeps EXECUTE.
--    Callers verified: wa_get_* and wa_supplier_latest_sent_po are called only by Edge Functions through the service-role
--    client; technician_installation_count, _next_ticket_available_for_technician, _customer_exemption_blocks,
--    _derive_payment_status and _largest_free_window are called only by SECURITY DEFINER functions (they run as the owner).
--    No policy, CHECK, column default, trigger or cron job references any of them.
--
-- Previous ACLs: Desktop\GV_mart_acl_backup_2026-10-12_anon_hygiene_batch2.json and the rollback file.

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
  if coalesce(auth.role(), '') <> 'service_role' then
    if p_org_id is distinct from public.current_org_id() then
      raise exception 'resolve_stale_bookings: org mismatch';
    end if;
    if not (public.current_customer_id() is not null
            or public.current_technician_is_active()
            or public.is_staff()) then
      raise exception 'resolve_stale_bookings: not permitted';
    end if;
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

do $rev$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('wa_get_business_info', 'wa_get_emi_info', 'wa_get_products_by_category',
                         'wa_supplier_latest_sent_po', 'technician_installation_count',
                         '_next_ticket_available_for_technician', '_customer_exemption_blocks',
                         '_derive_payment_status', '_largest_free_window')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$rev$;
