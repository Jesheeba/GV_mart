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
 * message and retried on the next flush pass (network blips, RLS races)
 * rather than being dropped — offline-first means "eventually consistent",
 * not "best effort". `attempts` is kept for future backoff/give-up UI but
 * nothing currently gives up permanently, matching "everything must queue
 * and work offline" in the DoD (silently losing a technician's field data
 * would violate that).
 */

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
      })
      if (error) throw error
      return
    }
    case "location.ping": {
      const { error } = await supabase.from("technician_locations").insert(p as unknown as TablesInsert<"technician_locations">)
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
    const jobs = await db.outbox.where("status").anyOf(["pending", "failed"]).sortBy("createdAt")
    for (const job of jobs) {
      if (!navigator.onLine) break
      try {
        await db.outbox.update(job.id!, { status: "syncing", updatedAt: Date.now() })
        await runJob(job)
        await db.outbox.delete(job.id!)
      } catch (err) {
        await db.outbox.update(job.id!, {
          status: "failed",
          attempts: job.attempts + 1,
          lastError: err instanceof Error ? err.message : String(err),
          updatedAt: Date.now(),
        })
        setState({ lastError: err instanceof Error ? err.message : String(err) })
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
