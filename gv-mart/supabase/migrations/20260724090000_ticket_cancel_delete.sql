-- Build Order Group A / A1: "Admin currently has NO way to cancel or delete
-- a service ticket."
--
-- `ticket_status` and `appointment_status` already carry a 'cancelled' label
-- (20260701090000_extensions_and_enums.sql) and TicketsListPage.tsx's
-- default "all" quick filter already excludes status='cancelled' from the
-- active view — so no enum change and no list-page change are needed here,
-- just the write path: a soft-cancel RPC (reason required) and a
-- conditional hard-delete RPC.
--
-- Hard delete is gated on the ticket having no financial record attached:
-- service_tickets.invoice_id (20260702100000_sales_phase5_schema.sql) is the
-- only FK that ties a ticket to real financial data — invoices, warranties,
-- and amc_contracts all link back to a *invoice*, never directly to a
-- service_ticket, so invoice_id is the one link that matters. A completed
-- visit with a recorded (nonzero) charge but no invoice yet is also treated
-- as financial and blocked, since create_service_invoice() (Phase 7) is what
-- normally turns that charge into invoice_id — a ticket can transiently be
-- "charged but not yet invoiced".

alter table public.service_tickets add column cancellation_reason text;
alter table public.service_tickets add column cancelled_at timestamptz;
alter table public.service_tickets add column cancelled_by uuid references public.profiles (id) on delete set null;

-- ── cancel_service_ticket: soft-cancel, reason required ──────────────────
create or replace function public.cancel_service_ticket(p_ticket_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket service_tickets;
begin
  if not public.is_ops_staff() then
    raise exception 'cancel_service_ticket: only master or operation_admin may cancel a ticket';
  end if;

  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'cancel_service_ticket: ticket % not found', p_ticket_id;
  end if;
  if v_ticket.org_id is distinct from public.current_org_id() then
    raise exception 'cancel_service_ticket: org mismatch';
  end if;
  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'cancel_service_ticket: a cancellation reason is required';
  end if;
  if v_ticket.status in ('completed', 'cancelled') then
    raise exception 'cancel_service_ticket: ticket is already % and cannot be cancelled', v_ticket.status;
  end if;

  update public.service_tickets
  set status = 'cancelled',
      cancellation_reason = trim(p_reason),
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      updated_at = now()
  where id = p_ticket_id;

  -- Free up any open appointment slot (mirrors the one-open-appointment
  -- partial-index scoping: only 'scheduled'/'in_progress' rows hold a slot).
  update public.appointments
  set status = 'cancelled', technician_id = null, updated_at = now()
  where ticket_id = p_ticket_id and status in ('scheduled', 'in_progress');

  return jsonb_build_object('ticket_id', p_ticket_id, 'status', 'cancelled');
end;
$$;

grant execute on function public.cancel_service_ticket(uuid, text) to authenticated;

-- ── delete_service_ticket: hard delete, only when nothing financial is
-- linked (see file header) ────────────────────────────────────────────────
create or replace function public.delete_service_ticket(p_ticket_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket service_tickets;
  v_charged_visit_id uuid;
begin
  if not public.is_ops_staff() then
    raise exception 'delete_service_ticket: only master or operation_admin may delete a ticket';
  end if;

  select * into v_ticket from public.service_tickets where id = p_ticket_id;
  if v_ticket.id is null then
    raise exception 'delete_service_ticket: ticket % not found', p_ticket_id;
  end if;
  if v_ticket.org_id is distinct from public.current_org_id() then
    raise exception 'delete_service_ticket: org mismatch';
  end if;

  if v_ticket.invoice_id is not null then
    raise exception 'delete_service_ticket: ticket has invoice % attached and cannot be hard-deleted — cancel it instead', v_ticket.invoice_id;
  end if;

  select id into v_charged_visit_id
  from public.service_visits
  where ticket_id = p_ticket_id and service_charge > 0
  limit 1;
  if v_charged_visit_id is not null then
    raise exception 'delete_service_ticket: ticket has a service visit with a recorded charge and cannot be hard-deleted — cancel it instead';
  end if;

  -- appointments / service_visits (and their sop_steps / spares_used /
  -- ro_checklists / ratings children) all reference service_tickets with
  -- `on delete cascade` (20260701090600_service.sql) — a plain delete here
  -- is enough.
  delete from public.service_tickets where id = p_ticket_id;
end;
$$;

grant execute on function public.delete_service_ticket(uuid) to authenticated;
