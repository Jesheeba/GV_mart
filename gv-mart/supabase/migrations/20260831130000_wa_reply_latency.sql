-- User report 2026-08-31: bot replies take ~10s. Measured real delivery
-- latency from whatsapp_outbox (inbound -> next outbound, last 500 rows):
-- median 2.1s, p90 4.7s, occasional spikes to 19s+ (one logged "Wasi
-- request timed out"). handleMessage makes ~9 SEQUENTIAL network round
-- trips per message today (dedupe insert, supplier identify, settings,
-- customer identify, get conversation, the real Wasi send, save-step,
-- expires_at bump) — at Supabase's own measured ~150-250ms per simple RPC
-- (direct timing, unrelated to this incident), that alone accounts for a
-- couple seconds before the third-party Wasi send is even reached, which
-- this migration can't touch.
--
-- This migration removes ONE of those round trips outright: the separate
-- `update whatsapp_conversations set expires_at = ...` at the end of every
-- turn (whatsapp-handle-message.ts, was its own .update() call after
-- wa_save_conversation_step already ran) is folded directly into
-- wa_save_conversation_step's own UPDATE. Same rule as before — only an
-- 'active' turn gets its timeout window refreshed, a terminal turn's
-- expires_at is left untouched — just expressed as one CASE inside the
-- single UPDATE instead of a second statement. Behavior-identical, one
-- fewer awaited call per message.
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
      -- 15 minutes mirrors STEP_TIMEOUT_MINUTES in whatsapp-handle-message.ts
      -- (the only caller) — keep the two in sync if either changes.
      expires_at = case when p_status = 'active' then now() + interval '15 minutes' else expires_at end,
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

-- Intentionally not re-granted — unchanged signature, create-or-replace
-- preserves existing grants (not granted to authenticated).
