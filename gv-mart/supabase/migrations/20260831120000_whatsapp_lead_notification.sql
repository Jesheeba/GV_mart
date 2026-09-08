-- User question 2026-08-31: "where do sales/admin get notified about an
-- AMC [lead]?" — traced definitively and the answer was nowhere. Every
-- WhatsApp-sourced lead (Sales journey, and the new AMC "add a plan?"
-- offer) converges on _whatsapp_lead_upsert (20260715210000), which inserts
-- into leads + lead_activities only — no notifications row, no trigger on
-- leads, no realtime subscription on the Leads page (checked all three).
-- Staff only ever saw these by manually opening Leads (master/sales_admin
-- only route). Same class of gap as the WhatsApp-ticket notification fix
-- (20260831090000) — that one covered tickets, this covers leads.
--
-- Fires once per genuinely NEW lead (the `v_lead_id is null` branch below),
-- not on every follow-up activity note appended to an already-open lead —
-- matching _auto_assign_ticket_internal's "notify on the event, not on
-- every touch" shape, and avoiding spamming sales_admin every time a
-- customer sends another message inside an already-open enquiry.
create or replace function public._whatsapp_lead_upsert(
  p_org_id uuid,
  p_from_mobile text,
  p_trigger public.enquiry_type,
  p_body text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_customer_name text;
  v_lead_id uuid;
  v_note text;
  v_is_new boolean := false;
begin
  select c.id, c.name into v_customer_id, v_customer_name
  from public.customers c
  where c.org_id = p_org_id and c.mobile = p_from_mobile
  limit 1;

  v_lead_id := public._find_recent_open_lead(p_org_id, v_customer_id, p_from_mobile);

  if v_lead_id is null then
    -- leads.name is not null. A raw inbound WhatsApp message carries no
    -- display name — NewLeadForm.tsx's manual lead path requires staff to
    -- type one (min 2 chars, no "unknown" convention to reuse), so there's
    -- no existing fallback pattern in this codebase to follow. Falls back
    -- to the mobile number itself, as suggested by the spec for this task.
    insert into public.leads (org_id, customer_id, name, mobile, source, enquiry_type, kind, status)
    values (p_org_id, v_customer_id, coalesce(v_customer_name, p_from_mobile), p_from_mobile, 'whatsapp', p_trigger, null, 'new')
    returning id into v_lead_id;
    v_is_new := true;
  end if;

  -- kind stays null: a raw WhatsApp topic keyword (price/quality/...) says
  -- nothing about service vs spare vs product.
  v_note := format('[%s] %s', coalesce(p_trigger::text, 'unmatched'), coalesce(p_body, ''));
  insert into public.lead_activities (org_id, lead_id, type, note)
  values (p_org_id, v_lead_id, 'whatsapp_enquiry', v_note);

  if v_is_new then
    insert into public.notifications (org_id, role, type, title, body, ref_id)
    values (p_org_id, 'sales_admin', 'wa_lead_captured', 'New WhatsApp lead',
      format('%s: %s', coalesce(v_customer_name, p_from_mobile), left(coalesce(p_body, ''), 200)), v_lead_id);
  end if;

  return v_lead_id;
end;
$$;

-- Intentionally not re-granted — unchanged signature, create-or-replace
-- preserves existing grants (not granted to authenticated).
