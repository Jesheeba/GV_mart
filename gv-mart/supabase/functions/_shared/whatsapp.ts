// WhatsApp transport adapter (plan decision #5: transport is OPEN, not
// decided yet — direct Meta Cloud API vs a BSP vs the user's own in-house
// Wasi platform is a business/vendor decision for the user to make before
// Phase 3). This is the one seam that choice plugs into later: every caller
// goes through sendMessage() below, and only this file's implementation
// changes when a provider is picked — nothing upstream of it does.
//
// For Phases 1-4, the only implementation is "log it" — the same
// log-not-dispatch behavior the existing send_whatsapp_stub RPC already
// uses elsewhere in this codebase (see 20260702170100_automation_purchase_
// functions.sql), reimplemented here as a direct table write because
// send_whatsapp_stub itself gates on is_staff(), which requires auth.uid()
// and doesn't apply to this Edge Function's service-role caller (decision #3).
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export type SendMessageInput = {
  orgId: string
  to: string // bare 10-digit, already normalized by the caller
  customerId: string | null
  template: string // e.g. "wa.menu", "wa.service.ack" — mirrors whatsapp_outbox.template
  body: string // human-readable text, logged into payload.body for now
  type?: "text" | "template" | "interactive" | "media"
  refType?: string | null
  refId?: string | null
}

export type SendMessageResult = {
  outboxId: string
  waMessageId: string | null
  dispatched: boolean // false in stub/log mode — nothing left this server
}

export async function sendMessage(admin: SupabaseClient, input: SendMessageInput): Promise<SendMessageResult> {
  // No provider is wired in yet — decision #5 is still open. When one is
  // picked, this function grows an `if (Deno.env.get("WHATSAPP_PROVIDER"))`
  // branch that calls out for real and fills in wa_message_id from the
  // provider's response; everything below stays the fallback.
  const { data, error } = await admin
    .from("whatsapp_outbox")
    .insert({
      org_id: input.orgId,
      direction: "outbound",
      to_mobile: input.to,
      customer_id: input.customerId,
      template: input.template,
      type: input.type ?? "text",
      payload: { body: input.body },
      ref_type: input.refType ?? null,
      ref_id: input.refId ?? null,
      status: "sent",
    })
    .select("id")
    .single()

  if (error) throw error

  return { outboxId: data.id, waMessageId: null, dispatched: false }
}
