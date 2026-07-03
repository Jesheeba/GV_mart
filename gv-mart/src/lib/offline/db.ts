import Dexie, { type EntityTable } from "dexie"

/**
 * Offline queue for the Technician App (Phase 7). Every technician-facing
 * write goes through this: it lands in `outbox` first (and, for entities the
 * UI needs to read back immediately — e.g. "my jobs today" while offline —
 * a mirrored read-cache table), then `sync.ts` flushes the outbox to
 * Supabase on reconnect. Nothing in `src/app/technician/**` calls
 * `supabase.from(...)`/`supabase.rpc(...)` directly for a write.
 *
 * Design: one `outbox` table holds pending mutations as opaque jobs (kind +
 * payload), replayed in insertion order. Read-cache tables mirror just
 * enough server shape to render job cards / job detail / history while
 * offline; they're refreshed opportunistically whenever a fetch succeeds
 * online (see `services/technician.ts`).
 */

export type OutboxKind =
  | "attendance.mark"
  | "attendance.lunch"
  | "spare_handover.confirm"
  | "service_visit.start"
  | "service_visit.image"
  | "service_visit.arrive"
  | "sop_step.complete"
  | "ro_checklist.save"
  | "service_invoice.create"
  | "rating.submit"
  | "lead.generate"
  | "location.ping"

export type OutboxStatus = "pending" | "syncing" | "failed"

export interface OutboxJob {
  id?: number
  kind: OutboxKind
  /** Client-generated id so dependent jobs (e.g. sop_step referencing a visit created offline) can chain before the server id exists. */
  clientRefId?: string
  payload: unknown
  status: OutboxStatus
  attempts: number
  lastError?: string
  createdAt: number
  updatedAt: number
}

/** Local mirror of `attendance` rows for today's read-through (own technician only, tiny table). */
export interface CachedAttendance {
  id: string // technician_id:date
  technicianId: string
  date: string
  data: unknown
  updatedAt: number
}

/** Local mirror of the day's route-ordered job cards (TECH-03). */
export interface CachedJob {
  id: string // appointment id
  ticketId: string
  data: unknown
  updatedAt: number
}

/** Local mirror of per-ticket detail + history (TECH-06/09). */
export interface CachedJobDetail {
  ticketId: string
  data: unknown
  updatedAt: number
}

/** Locally-created service visit not yet synced — lets TECH-07 proceed fully offline before the server row exists. */
export interface DraftVisit {
  clientId: string // uuid generated on-device
  ticketId: string
  serverId?: string
  data: Record<string, unknown>
  updatedAt: number
}

/** Captured photo/signature blobs, referenced by clientId from DraftVisit/outbox payloads until synced. */
export interface CachedMedia {
  id: string // uuid
  kind: "before" | "after" | "selfie" | "signature_tech" | "signature_admin" | "signature_customer"
  dataUrl: string
  meta?: { lat?: number; lng?: number; capturedAt: string }
  createdAt: number
}

export interface CachedSettings {
  orgId: string
  data: unknown
  updatedAt: number
}

const db = new Dexie("gv_mart_technician") as Dexie & {
  outbox: EntityTable<OutboxJob, "id">
  attendanceCache: EntityTable<CachedAttendance, "id">
  jobsCache: EntityTable<CachedJob, "id">
  jobDetailCache: EntityTable<CachedJobDetail, "ticketId">
  draftVisits: EntityTable<DraftVisit, "clientId">
  media: EntityTable<CachedMedia, "id">
  settingsCache: EntityTable<CachedSettings, "orgId">
}

db.version(1).stores({
  outbox: "++id, kind, status, createdAt",
  attendanceCache: "id, technicianId, date",
  jobsCache: "id, ticketId",
  jobDetailCache: "ticketId",
  draftVisits: "clientId, ticketId, serverId",
  media: "id, kind, createdAt",
  settingsCache: "orgId",
})

export { db }
