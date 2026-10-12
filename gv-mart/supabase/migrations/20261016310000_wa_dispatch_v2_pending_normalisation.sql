-- WhatsApp dispatcher v2, step 2 of 2: milestone writers insert 'pending', not an optimistic 'sent'.
-- See docs/plan-dispatcher-fix.md (a)/(i): this is the "trigger bodies last" step.
--
-- Why a single normalising BEFORE INSERT trigger instead of editing every writer's function body:
-- whatsapp_outbox is written by ~10 SECURITY DEFINER functions defined across 8 migrations (the three milestone triggers,
-- the supplier RFQ fan-out, send_staff_whatsapp, ...). Re-creating all of them would copy stale bodies and risks clobbering
-- parallel work (see the shared-RPC collision note). One row-level rule here gives the same result for every present and
-- future writer, and is inert unless settings.wa_dispatch_v2_enabled is on, so it can be applied before the flag flips and
-- is reverted by switching the flag off (no function redeploy).
--
-- Only rows the dispatcher actually picks up are normalised (ref types service_ticket, service_visit, invoice,
-- purchase_quote_request). purchase_order rows are never dispatched (a separate, known gap) and stay as they are.
-- A real send made by Edge Function code already inserts 'pending' explicitly, so those rows pass through untouched.

create or replace function public._trg_wa_outbox_pending_normalise()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.direction = 'outbound'
     and new.status = 'sent'
     and new.wa_message_id is null
     and new.ref_type in ('service_ticket', 'service_visit', 'invoice', 'purchase_quote_request')
     and exists (select 1 from public.settings s where s.org_id = new.org_id and s.wa_dispatch_v2_enabled)
  then
    new.status := 'pending';
  end if;
  return new;
end;
$$;

revoke all on function public._trg_wa_outbox_pending_normalise() from public, anon, authenticated;

drop trigger if exists wa_outbox_pending_normalise on public.whatsapp_outbox;
create trigger wa_outbox_pending_normalise
  before insert on public.whatsapp_outbox
  for each row execute function public._trg_wa_outbox_pending_normalise();
