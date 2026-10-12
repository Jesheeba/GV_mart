// WhatsApp test-mode allow-list (review F-08). When settings.wa_test_mode_enabled is true, a message may only be sent
// to a number listed in settings.wa_test_allowed_numbers; anything else is blocked and logged. This is checked at the one
// place a message actually leaves the system (sendMessage in whatsapp.ts), so every sender - the bot, the milestone
// dispatcher, the failed-send retry pass - is covered. send_staff_whatsapp() applies the same rule when a staff user
// queues a message. The switch ships OFF.
//
// Fails CLOSED on a read error: if the settings row cannot be read we do not know whether test mode is on, and the
// harm test mode exists to prevent (a real customer receiving a test message) is worse than one retried send.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export type TestModeVerdict =
  | { blocked: false }
  | { blocked: true; reason: "test_mode_not_allow_listed" | "settings_unreadable" }

/** Bare 10 digits, the form every stored mobile uses. */
export function toBareMobile(raw: string | null | undefined): string {
  return (raw ?? "").replace(/\D/g, "").slice(-10)
}

export async function evaluateTestMode(admin: SupabaseClient, orgId: string, to: string): Promise<TestModeVerdict> {
  const { data, error } = await admin
    .from("settings")
    .select("wa_test_mode_enabled, wa_test_allowed_numbers")
    .eq("org_id", orgId)
    .abortSignal(AbortSignal.timeout(5_000))
    .maybeSingle()

  if (error) {
    console.error("wa-test-mode: settings read failed, blocking this send", error.message)
    return { blocked: true, reason: "settings_unreadable" }
  }
  if (!data || data.wa_test_mode_enabled !== true) return { blocked: false }

  const allowed = new Set(((data.wa_test_allowed_numbers ?? []) as string[]).map(toBareMobile))
  return allowed.has(toBareMobile(to)) ? { blocked: false } : { blocked: true, reason: "test_mode_not_allow_listed" }
}

/** audit_log is append-only; this only ever INSERTs. Keeps just the last four digits of the number. */
export async function logBlockedSend(
  admin: SupabaseClient,
  info: { orgId: string; to: string; template: string; refType: string | null; refId: string | null; reason: string; outboxId?: string | null }
): Promise<void> {
  const { error } = await admin.from("audit_log").insert({
    org_id: info.orgId,
    actor_id: null,
    action: "WA_SEND_BLOCKED",
    table_name: "whatsapp_outbox",
    row_id: info.outboxId ?? info.refId,
    after: { reason: info.reason, via: "sendMessage", template: info.template, ref_type: info.refType, to_last4: toBareMobile(info.to).slice(-4) },
  })
  if (error) console.error("wa-test-mode: could not write the WA_SEND_BLOCKED audit row", error.message)
}
