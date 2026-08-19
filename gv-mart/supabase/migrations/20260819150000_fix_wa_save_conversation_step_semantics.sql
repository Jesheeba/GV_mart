-- Phase 2b Step 1 fix: wa_save_conversation_step (20260819120000) used
-- `journey = coalesce(p_journey, journey)`, treating a null argument as
-- "leave this field unchanged" — a reasonable-looking default that's wrong
-- for this caller. The webhook's routeInbound() always computes the FULL
-- next state and needs to be able to genuinely clear journey back to null
-- (e.g. "back to main menu" from inside a journey). Coalesce silently kept
-- the old journey instead.
--
-- Fix: direct assignment for every field. The only real caller
-- (whatsapp-webhook) always passes the complete next state, never a
-- partial patch, so there's no remaining use for "null means unchanged"
-- semantics here.
create or replace function public.wa_save_conversation_step(
  p_org_id uuid,
  p_phone text,
  p_journey text,
  p_step text,
  p_collected jsonb default '{}'::jsonb,
  p_customer_id uuid default null,
  p_status text default 'active'
)
returns whatsapp_conversations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_phone text;
  v_row whatsapp_conversations;
begin
  v_phone := public._wa_normalize_phone(p_phone);
  if v_phone is null then
    raise exception 'wa_save_conversation_step: % is not a resolvable phone number', p_phone;
  end if;
  if p_status not in ('active', 'completed', 'expired', 'handed_off') then
    raise exception 'wa_save_conversation_step: invalid status %', p_status;
  end if;

  update public.whatsapp_conversations
  set journey = p_journey,
      step = p_step,
      collected = coalesce(p_collected, collected),
      customer_id = coalesce(p_customer_id, customer_id),
      status = p_status,
      last_message_at = now(),
      updated_at = now()
  where org_id = p_org_id and phone = v_phone and status = 'active'
  returning * into v_row;

  if v_row.id is null then
    raise exception 'wa_save_conversation_step: no active conversation for %, call wa_get_conversation first', v_phone;
  end if;

  return v_row;
end;
$$;
