-- Phase B of the gvm_* basic lifecycle automation (see build-docs/features/
-- basic-lifecycle-automation.md). Chunk A (20261204210000) wired the 7 events
-- that already had a live trigger (ticket/visit/invoice/amc_reminder/feedback).
-- This phase adds the remaining events from the original 12-template batch:
-- lead created, quotation generated, AMC contract registered, payment
-- received, and installation completed. Same shape as the existing
-- _milestone_* triggers in 20260702170100_automation_purchase_functions.sql —
-- no try/catch added, because none of the originals have any either; a
-- failure here is expected to surface the same way those already do.

-- ── Lead created → milestone.lead_created ──────────────────────────────────
-- Leads don't always have a customer_id yet (pre-conversion) — to_mobile and
-- customer_id are both nullable on whatsapp_outbox precisely for this reason
-- (see its own column comments), so this fires even for a brand-new,
-- not-yet-converted lead. wa-event-context.ts's 'lead' branch resolves the
-- customer_name/product_name straight off the lead row, not through
-- customer_id, for the same reason.
create or replace function public._milestone_lead_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
  values (new.org_id, 'outbound', new.mobile, new.customer_id, 'lead_created', 'milestone.lead_created',
          jsonb_build_object('lead_id', new.id), 'lead', new.id, 'sent');
  return new;
end;
$$;

drop trigger if exists leads_milestone_notify on public.leads;
create trigger leads_milestone_notify
  after insert on public.leads
  for each row execute function public._milestone_lead_notify();

-- ── Quotation generated → milestone.quotation_generated ───────────────────
-- quotation_status has no "draft"/"sent" distinction (just open/converted/
-- lost — see the enum) — a row only exists once it's actually generated, so
-- AFTER INSERT is the right (and only) signal, same reasoning as
-- _milestone_invoice_notify. customer_id is nullable on quotations (a
-- lead-only quote before conversion), so the mobile is resolved from
-- whichever side is populated.
create or replace function public._milestone_quotation_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mobile text;
begin
  if new.customer_id is not null then
    select mobile into v_mobile from public.customers where id = new.customer_id;
  elsif new.lead_id is not null then
    select mobile into v_mobile from public.leads where id = new.lead_id;
  end if;

  insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
  values (new.org_id, 'outbound', v_mobile, new.customer_id, 'quotation_generated', 'milestone.quotation_generated',
          jsonb_build_object('quotation_id', new.id, 'lead_id', new.lead_id), 'quotation', new.id, 'sent');
  return new;
end;
$$;

drop trigger if exists quotations_milestone_notify on public.quotations;
create trigger quotations_milestone_notify
  after insert on public.quotations
  for each row execute function public._milestone_quotation_notify();

-- ── AMC contract registered → milestone.amc_registered ─────────────────────
-- amc_contracts.customer_id is NOT NULL (unlike leads/quotations above), so
-- this is a plain copy of _milestone_invoice_notify's shape.
create or replace function public._milestone_amc_contract_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
begin
  select id, mobile into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_customer.mobile, v_customer.id, 'amc_registered', 'milestone.amc_registered',
            jsonb_build_object('amc_contract_id', new.id, 'product_id', new.product_id), 'amc_contract', new.id, 'sent');
  end if;
  return new;
end;
$$;

drop trigger if exists amc_contracts_milestone_notify on public.amc_contracts;
create trigger amc_contracts_milestone_notify
  after insert on public.amc_contracts
  for each row execute function public._milestone_amc_contract_notify();

-- ── Payment received → milestone.payment_received ──────────────────────────
-- payments (20260806092000_payments_table.sql) is append-only and only ever
-- inserts 'paid' rows, so AFTER INSERT = a confirmed payment, no status check
-- needed. BUT: the approved gvm_payment_received body says "...against
-- Complaint No. {{complaint_number}}" — that only makes sense for a
-- visit-scoped (service-ticket) payment, not a counter/admin product sale
-- (create_sale), which has no ticket at all. visit_id is nullable precisely
-- to cover both cases (see that table's own column comment), so this
-- deliberately only fires when visit_id is present, to avoid sending a
-- "Complaint No." message against a plain product purchase. A sale-invoice
-- payment-received message, if wanted later, needs a template of its own
-- (flagged to the product owner, not built here).
create or replace function public._milestone_payment_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ticket_id uuid;
  v_customer_id uuid;
  v_mobile text;
begin
  -- Gate on invoice_id -> service_tickets, not visit_id: record_upi_payment (technician,
  -- always full amount) sets visit_id, but record_additional_payment (master/sales_admin,
  -- the only partial-payment path) always leaves visit_id null even for ticket-linked
  -- invoices -- gating on visit_id silently skipped every admin-recorded payment, partial
  -- or full. new.amount is this one payment row's amount, so installments each fire their
  -- own correct message instead of repeating the invoice total. Invoices with no linked
  -- service ticket (plain product sales) still resolve to no ticket and are skipped --
  -- gvm_payment_received's approved wording requires a Complaint No., which a sale has none of.
  select st.id, c.id, c.mobile into v_ticket_id, v_customer_id, v_mobile
  from public.service_tickets st
  join public.customers c on c.id = st.customer_id
  where st.invoice_id = new.invoice_id;

  if v_customer_id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_mobile, v_customer_id, 'payment_received', 'milestone.payment_received',
            jsonb_build_object('payment_id', new.id, 'ticket_id', v_ticket_id, 'amount', new.amount), 'payment', new.id, 'sent');
  end if;
  return new;
end;
$$;

drop trigger if exists payments_milestone_notify on public.payments;
create trigger payments_milestone_notify
  after insert on public.payments
  for each row execute function public._milestone_payment_notify();

-- ── Installation completed → milestone.installation_completed ─────────────
-- NOT a new table-level trigger: service_tickets already fires
-- _milestone_ticket_notify on completion for every ticket type, and that
-- single outbox row already carried new.type in its payload. The only
-- missing piece was a distinct event_key so an installation-type completion
-- can map to gvm_installation_completed instead of gvm_service_completed —
-- this replaces that one function with an added type-aware branch, same
-- insert shape, nothing else changed (booked/assigned paths untouched).
create or replace function public._milestone_ticket_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer record;
  v_milestone text;
begin
  if tg_op = 'INSERT' then
    v_milestone := 'booked';
  elsif tg_op = 'UPDATE' and new.status = 'assigned' and old.status is distinct from 'assigned' then
    v_milestone := 'assigned';
  elsif tg_op = 'UPDATE' and new.status = 'completed' and old.status is distinct from 'completed' then
    v_milestone := case when new.type = 'installation' then 'installation_completed' else 'completed' end;
  else
    return new;
  end if;

  select id, mobile into v_customer from public.customers where id = new.customer_id;
  if v_customer.id is not null then
    insert into public.whatsapp_outbox (org_id, direction, to_mobile, customer_id, milestone, template, payload, ref_type, ref_id, status)
    values (new.org_id, 'outbound', v_customer.mobile, v_customer.id, v_milestone, 'milestone.' || v_milestone,
            jsonb_build_object('ticket_id', new.id, 'type', new.type), 'service_ticket', new.id, 'sent');
  end if;

  return new;
end;
$$;
-- Trigger itself (service_tickets_milestone_notify, after insert or update of
-- status) is untouched — create or replace above is enough to pick this up.

-- ── whatsapp_event_templates mapping rows for all 5 new event_keys ─────────
do $mig$
begin
  if to_regclass('public.whatsapp_event_templates') is null then
    raise exception 'wire_gvm_templates_phase_b: whatsapp_event_templates missing -- base schema not applied';
  end if;

  insert into public.whatsapp_event_templates (org_id, event_key, language, wasi_template_name, param_map)
  select o.id, v.event_key, 'en', v.wasi_template_name, v.param_map::jsonb
  from public.organizations o
  cross join (
    values
      ('milestone.lead_created',             'gvm_product_enquiry',       '{"customer_name":"customer_name","product_name":"product_name","enquiry_number":"enquiry_number"}'),
      ('milestone.quotation_generated',      'gvm_quotation_generated',   '{"customer_name":"customer_name","product_name":"product_name","quotation_number":"quotation_number","amount":"amount"}'),
      ('milestone.amc_registered',           'gvm_amc_registration',      '{"customer_name":"customer_name","amc_number":"amc_number","expiry_date":"expiry_date"}'),
      ('milestone.payment_received',         'gvm_payment_received',      '{"customer_name":"customer_name","amount":"amount","complaint_number":"complaint_number"}'),
      ('milestone.installation_completed',   'gvm_installation_completed','{"customer_name":"customer_name","product_name":"product_name"}')
  ) as v(event_key, wasi_template_name, param_map)
  on conflict (org_id, event_key, language) do update
    set wasi_template_name = excluded.wasi_template_name,
        param_map = excluded.param_map;

  if (select count(*) from public.whatsapp_event_templates where event_key like 'milestone.%' and event_key not in (
      'milestone.booked', 'milestone.assigned', 'milestone.on_the_way', 'milestone.completed', 'milestone.invoice'
  )) < 5 then
    raise exception 'assertion failed: expected at least 5 new phase-b gvm_* mapping rows';
  end if;
end
$mig$;
