import { supabase } from "@/lib/supabase"
import type { Json, TablesInsert, TablesUpdate } from "@/types/database"
import { db, type OutboxJob } from "./db"

/**
 * Flushes the Dexie outbox to Supabase, in insertion order, on reconnect and
 * on a periodic timer while online. Each job kind maps to exactly one
 * Supabase call (a direct table write where RLS already allows the
 * technician's own row, or one of the Phase 7 RPCs where it doesn't — see
 * `supabase/migrations/20260702120000_technician_phase7_functions.sql`).
 *
 * Failure handling: a job that fails is marked `failed` with the error
 * message and retried (network blips, RLS races) rather than being dropped —
 * offline-first means "eventually consistent", not "best effort". A failed
 * job backs off exponentially (`backoffDelayMs`) instead of being retried on
 * every 20s tick, and after `MAX_ATTEMPTS_BEFORE_STUCK` consecutive failures
 * it's marked `stuck` and stops being auto-retried — but it is NOT dropped:
 * `stuck` means "needs a human to look at it" (surfaced via the sync-status
 * chip's stuck-jobs panel), never "given up on for good". A technician can
 * manually retry a stuck job (`retryStuckJob` in outbox.ts), which puts it
 * straight back in the normal rotation. This still honors "everything must
 * queue and work offline" in the DoD — silently losing a technician's field
 * data would violate that; going quiet about a job that keeps failing would
 * violate it just as much, which is why `stuck` exists.
 */

/** A job that just failed waits at least one full poll tick before its next try — 20s, 40s, 80s, ... capped at 10 minutes. */
const BASE_BACKOFF_MS = 20_000
const MAX_BACKOFF_MS = 10 * 60_000
/**
 * After this many consecutive failures (with the schedule above, roughly 40
 * minutes of retrying — 20+40+80+160+320+600+600+600s), stop auto-retrying
 * and mark the job `stuck` instead of retrying forever indistinguishably
 * from a job that has only just failed once. Chosen to comfortably outlast
 * a flaky connection or a brief Supabase/RLS blip while still surfacing a
 * genuinely broken job (bad payload, permanently revoked access, etc.)
 * within the same shift rather than retrying it silently forever.
 */
const MAX_ATTEMPTS_BEFORE_STUCK = 8

function backoffDelayMs(attempts: number): number {
  return Math.min(BASE_BACKOFF_MS * 2 ** (attempts - 1), MAX_BACKOFF_MS)
}

type Listener = (state: SyncState) => void
export type SyncState = { syncing: boolean; lastError: string | null; lastSyncedAt: number | null }

let state: SyncState = { syncing: false, lastError: null, lastSyncedAt: null }
const listeners = new Set<Listener>()

function setState(patch: Partial<SyncState>) {
  state = { ...state, ...patch }
  listeners.forEach((l) => l(state))
}

export function subscribeSyncState(cb: Listener) {
  listeners.add(cb)
  cb(state)
  return () => listeners.delete(cb)
}

export function getSyncState() {
  return state
}

async function runJob(job: OutboxJob): Promise<void> {
  const p = job.payload as Record<string, unknown>
  switch (job.kind) {
    case "attendance.mark": {
      const { error } = await supabase.from("attendance").upsert(p as unknown as TablesInsert<"attendance">, { onConflict: "technician_id,date" })
      if (error) throw error
      return
    }
    case "attendance.lunch": {
      const { error } = await supabase
        .from("attendance")
        .update(p.patch as TablesUpdate<"attendance">)
        .eq("technician_id", p.technicianId as string)
        .eq("date", p.date as string)
      if (error) throw error
      return
    }
    case "attendance.checkout": {
      const { error } = await supabase
        .from("attendance")
        .update({ check_out_at: p.checkOutAt } as unknown as TablesUpdate<"attendance">)
        .eq("technician_id", p.technicianId as string)
        .eq("date", p.date as string)
      if (error) throw error
      return
    }
    case "spare_handover.confirm": {
      const { error } = await supabase.rpc("confirm_spare_handover", {
        p_handover_id: p.handoverId as string,
        p_tech_sign_url: p.techSignUrl as string,
        p_admin_sign_url: p.adminSignUrl as string,
      })
      if (error) throw error
      return
    }
    case "service_visit.start": {
      const { error } = await supabase.from("service_visits").upsert(p as unknown as TablesInsert<"service_visits">, { onConflict: "id" })
      if (error) throw error
      return
    }
    case "service_visit.arrive": {
      const { error } = await supabase
        .from("service_visits")
        .update(p.patch as TablesUpdate<"service_visits">)
        .eq("id", p.visitId as string)
      if (error) throw error
      return
    }
    case "service_visit.image": {
      const patch = { [p.column as string]: p.url as string } as TablesUpdate<"service_visits">
      const { error } = await supabase.from("service_visits").update(patch).eq("id", p.visitId as string)
      if (error) throw error
      return
    }
    case "sop_step.complete": {
      const { error } = await supabase.from("service_sop_steps").upsert(p as unknown as TablesInsert<"service_sop_steps">, { onConflict: "id" })
      if (error) throw error
      return
    }
    case "ro_checklist.save": {
      const { error } = await supabase.from("ro_checklists").upsert(p as unknown as TablesInsert<"ro_checklists">, { onConflict: "visit_id" })
      if (error) throw error
      return
    }
    case "service_invoice.create": {
      const { error } = await supabase.rpc("create_service_invoice", {
        p_org_id: p.orgId as string,
        p_visit_id: p.visitId as string,
        p_service_charge: p.serviceCharge as number,
        p_discount_percent: p.discountPercent as number,
        p_spares: p.spares as Json,
        p_payment_method: p.paymentMethod as "cash" | "transfer",
        p_txn_id: (p.txnId as string) ?? null,
        p_payment_description: (p.paymentDescription as string) ?? null,
        p_is_chargeable: p.isChargeable as boolean,
      })
      if (error) throw error
      return
    }
    case "rating.submit": {
      const { error } = await supabase.rpc("submit_rating", {
        p_org_id: p.orgId as string,
        p_visit_id: p.visitId as string,
        p_stars: p.stars as number,
        p_review: (p.review as string) ?? null,
        p_low_rating_reason: (p.lowRatingReason as string) ?? null,
      })
      if (error) throw error
      return
    }
    case "lead.generate": {
      const { error } = await supabase.rpc("generate_enquiry_lead", {
        p_org_id: p.orgId as string,
        p_customer_id: (p.customerId as string) ?? null,
        p_name: p.name as string,
        p_mobile: (p.mobile as string) ?? null,
        p_enquiry_type: p.enquiryType as "online" | "price" | "quality" | "customization" | "water_premium" | "budget",
        p_note: (p.note as string) ?? null,
        p_visit_id: (p.visitId as string) ?? null,
      })
      if (error) throw error
      return
    }
    case "rating.mark_review_clicked": {
      const { error } = await supabase.rpc("mark_google_review_clicked", {
        p_org_id: p.orgId as string,
        p_visit_id: p.visitId as string,
      })
      if (error) throw error
      return
    }
    case "location.ping": {
      const { error } = await supabase.from("technician_locations").insert(p as unknown as TablesInsert<"technician_locations">)
      if (error) throw error
      return
    }
    case "amc.sell_onsite": {
      const { error } = await supabase.rpc("sell_amc_plan_onsite", {
        p_org_id: p.orgId as string,
        p_customer_id: p.customerId as string,
        p_product_id: p.productId as string,
        p_plan_id: p.planId as string,
        p_payment_method: p.paymentMethod as "cash" | "transfer",
        p_txn_id: (p.txnId as string) ?? null,
        p_payment_description: (p.paymentDescription as string) ?? null,
      })
      if (error) throw error
      return
    }
    default: {
      const exhaustive: never = job.kind as never
      throw new Error(`Unknown outbox job kind: ${String(exhaustive)}`)
    }
  }
}

let flushing = false

export async function flushOutbox() {
  if (flushing) return
  if (!navigator.onLine) return
  flushing = true
  setState({ syncing: true })
  try {
    const now = Date.now()
    // "stuck" jobs are deliberately excluded — they only leave that state via
    // an explicit technician retry (outbox.ts's retryStuckJob), not this loop.
    const jobs = await db.outbox.where("status").anyOf(["pending", "failed"]).sortBy("createdAt")
    // A job that has never failed has no nextRetryAt and is always due —
    // this is what keeps the happy path (succeeds on 1st/2nd try) exactly as
    // fast as before; only jobs that have already failed at least once wait.
    const due = jobs.filter((job) => !job.nextRetryAt || job.nextRetryAt <= now)
    for (const job of due) {
      if (!navigator.onLine) break
      try {
        await db.outbox.update(job.id!, { status: "syncing", updatedAt: Date.now() })
        await runJob(job)
        await db.outbox.delete(job.id!)
      } catch (err) {
        const attempts = job.attempts + 1
        const lastError = err instanceof Error ? err.message : String(err)
        const stuck = attempts >= MAX_ATTEMPTS_BEFORE_STUCK
        await db.outbox.update(job.id!, {
          status: stuck ? "stuck" : "failed",
          attempts,
          lastError,
          firstFailedAt: job.firstFailedAt ?? Date.now(),
          nextRetryAt: stuck ? undefined : Date.now() + backoffDelayMs(attempts),
          updatedAt: Date.now(),
        })
        setState({ lastError })
      }
    }
    setState({ lastSyncedAt: Date.now() })
  } finally {
    flushing = false
    setState({ syncing: false })
  }
}

let started = false
let intervalHandle: ReturnType<typeof setInterval> | null = null

/** Wires the `online` event + a periodic retry timer. Call once, near app root (technician shell). Idempotent. */
export function startSyncEngine() {
  if (started) return
  started = true
  window.addEventListener("online", () => void flushOutbox())
  intervalHandle = setInterval(() => void flushOutbox(), 20_000)
  if (navigator.onLine) void flushOutbox()
}

export function stopSyncEngine() {
  if (intervalHandle) clearInterval(intervalHandle)
  intervalHandle = null
  started = false
}
