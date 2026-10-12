// Wasi WhatsApp BSP connector — inbound webhook. Additive alongside
// whatsapp-webhook (Meta's direct webhook): both call the same shared
// handleMessage() (see _shared/whatsapp-handle-message.ts), each owning
// only its own provider's wire format and authenticity check. No GET
// verification handshake — confirmed with Wasi this isn't needed, unlike
// Meta's hub.challenge dance.
//
// Wasi's webhook_secret is per-org (credential storage in
// whatsapp_provider_credentials), not a single env var — so org resolution
// happens BEFORE signature verification: message.received resolves the org
// from the payload's waba_id, message.status from the outbox row we created
// when the message was sent (matched on the WhatsApp message id). A payload
// field is only used to pick which secret to check; nothing is written before
// the signature passes.
//
// All decision logic lives in _shared/wasi-webhook.handler.ts (unit-tested, no
// Deno imports). This file only builds the real store and the real `defer`:
// a verified event is acknowledged with 200 immediately and processed after the
// response (EdgeRuntime.waitUntil), because Wasi retries for ~8.5 hours.
// See docs/plan-dispatcher-fix.md (d).
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { handleMessage } from "../_shared/whatsapp-handle-message.ts"
import { handleWasiWebhook, type WebhookStore } from "../_shared/wasi-webhook.handler.ts"

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function buildStore(admin: SupabaseClient): WebhookStore {
  return {
    async findCredentialsByWabaId(wabaId) {
      const { data } = await admin
        .from("whatsapp_provider_credentials")
        .select("org_id, webhook_secret")
        .eq("provider", "wasi")
        .eq("waba_id", wabaId)
        .eq("is_active", true)
        .maybeSingle()
      return data ? { orgId: data.org_id as string, webhookSecret: data.webhook_secret as string } : null
    },
    async findOutboxByWhatsAppId(messageId) {
      const { data: row } = await admin
        .from("whatsapp_outbox")
        .select("id, org_id, delivery_status, delivered_at, read_at")
        .eq("wa_message_id", messageId)
        .maybeSingle()
      if (!row) return null
      const { data: cred } = await admin
        .from("whatsapp_provider_credentials")
        .select("webhook_secret")
        .eq("provider", "wasi")
        .eq("org_id", row.org_id)
        .eq("is_active", true)
        .maybeSingle()
      if (!cred) return null
      return {
        id: row.id as string,
        orgId: row.org_id as string,
        webhookSecret: cred.webhook_secret as string,
        delivery_status: (row.delivery_status as string | null) ?? null,
        delivered_at: (row.delivered_at as string | null) ?? null,
        read_at: (row.read_at as string | null) ?? null,
      }
    },
    async applyDeliveryUpdate(id, patch) {
      const { error } = await admin.from("whatsapp_outbox").update(patch).eq("id", id)
      if (error) throw error
    },
    async upsertTemplateStatus(orgId, wasiName, status) {
      const { error } = await admin
        .from("whatsapp_wasi_templates")
        .update({ status, synced_at: new Date().toISOString() })
        .eq("org_id", orgId)
        .eq("wasi_name", wasiName)
      if (error) throw error
    },
    processInbound: (orgId, msg) => handleMessage(admin, orgId, msg),
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: "Not configured (missing Supabase service credentials)" }, 500)
  }

  const rawBody = await req.text()
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  // EdgeRuntime.waitUntil lets the response go out first; without it (local runs) the work is awaited inline.
  const edge = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime
  const pending: Promise<unknown>[] = []
  const defer = (work: Promise<unknown>) => {
    if (edge?.waitUntil) edge.waitUntil(work)
    else pending.push(work)
  }

  const result = await handleWasiWebhook(rawBody, req.headers.get("x-wasi-signature-256"), buildStore(admin), defer)
  if (pending.length > 0) await Promise.all(pending)
  return jsonResponse(result.body, result.status)
})
