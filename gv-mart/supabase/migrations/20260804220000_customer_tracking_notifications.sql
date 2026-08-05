-- Premium Live Tracking (customer app) — in-app notifications for the three
-- lifecycle moments the tracking screen cares about: technician assigned,
-- technician started the visit, service completed.
--
-- Deliberately trigger-based rather than patching the assignment RPCs
-- (_auto_assign_ticket_internal / _auto_assign_next_ticket_to_technician /
-- assign_ticket_technician) or the two completion paths
-- (create_service_invoice / complete_appointment): 20260702170100_
-- automation_purchase_functions.sql already established exactly this
-- pattern for the WhatsApp-stub milestone system (_milestone_ticket_notify
-- on service_tickets "after insert or update of status", _milestone_visit_
-- notify on service_visits "after insert" — same comment there: visit
-- INSERT is the closest real signal to "on the way/arrived", not a literal
-- GPS-departure event). Mirroring that shape here means zero RPC bodies are
-- touched (no collision risk with parallel work on those five functions)
-- and any future assignment/completion path gets covered automatically.
--
-- This inserts into public.notifications (in-app, drives NotificationsPage
-- + the unread badge) — a separate concern from whatsapp_outbox, which is
-- a logged-only stub with no real dispatch. ref_id is the ticket id (not
-- the appointment id, unlike the technician-facing 'appointment_assigned'
-- notification) so the client can deep-link straight to
-- /customer/bookings/:ref_id.

create or replace function public._notify_customer_ticket_milestone()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
begin
  if tg_op = 'UPDATE' and new.status = 'assigned' and old.status is distinct from 'assigned' then
    select c.primary_profile_id into v_profile_id from public.customers c where c.id = new.customer_id;
    if v_profile_id is not null then
      insert into public.notifications (org_id, user_id, type, title, body, ref_id)
      values (
        new.org_id, v_profile_id, 'technician_assigned', 'Technician assigned',
        'A technician has been assigned to your request. Track your technician live.', new.id
      );
    end if;
  elsif tg_op = 'UPDATE' and new.status = 'completed' and old.status is distinct from 'completed' then
    select c.primary_profile_id into v_profile_id from public.customers c where c.id = new.customer_id;
    if v_profile_id is not null then
      insert into public.notifications (org_id, user_id, type, title, body, ref_id)
      values (
        new.org_id, v_profile_id, 'service_completed', 'Service completed',
        'Your service has been completed. Thank you for choosing us!', new.id
      );
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists service_tickets_customer_milestone_notify on public.service_tickets;
create trigger service_tickets_customer_milestone_notify
  after update of status on public.service_tickets
  for each row execute function public._notify_customer_ticket_milestone();

create or replace function public._notify_customer_visit_started()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket record;
  v_profile_id uuid;
begin
  select id, org_id, customer_id into v_ticket from public.service_tickets where id = new.ticket_id;
  if v_ticket.customer_id is null then
    return new;
  end if;

  select c.primary_profile_id into v_profile_id from public.customers c where c.id = v_ticket.customer_id;
  if v_profile_id is not null then
    insert into public.notifications (org_id, user_id, type, title, body, ref_id)
    values (
      v_ticket.org_id, v_profile_id, 'service_started', 'Technician has arrived',
      'Your technician has arrived and started the service.', v_ticket.id
    );
  end if;

  return new;
end;
$$;

drop trigger if exists service_visits_customer_milestone_notify on public.service_visits;
create trigger service_visits_customer_milestone_notify
  after insert on public.service_visits
  for each row execute function public._notify_customer_visit_started();
