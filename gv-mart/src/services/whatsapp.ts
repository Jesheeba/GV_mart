import { supabase } from "@/lib/supabase"

/**
 * Best-effort nudge for the wa-dispatch-now Edge Function, called right
 * after a mutation that a milestone DB trigger (booking confirmed,
 * technician assigned, on-the-way, invoice) turns into a pending
 * whatsapp_outbox row. Deliberately fire-and-forget: never awaited by
 * callers, never throws, never surfaces an error to the UI. The 5-minute
 * wa-milestone-dispatch cron poller is the real safety net — if this call
 * fails for any reason (offline, Wasi down, a cold-started function
 * timing out), the poller finds the same row on its own within 5 minutes.
 * No org id needed: the Edge Function resolves the caller's org from their
 * own session.
 */
export function triggerWaDispatchNow(): void {
  void supabase.functions.invoke("wa-dispatch-now", { body: {} }).catch((err) => {
    console.error("triggerWaDispatchNow: best-effort dispatch failed, poller will retry", err)
  })
}
