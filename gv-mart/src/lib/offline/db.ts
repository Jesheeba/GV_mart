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
  | "attendance.checkout"
  | "spare_handover.confirm"
  | "service_visit.start"
  | "service_visit.image"
  | "service_visit.arrive"
  | "sop_step.complete"
  | "ro_checklist.save"
  | "service_invoice.create"
  | "rating.submit"
  | "rating.mark_review_clicked"
  | "lead.generate"
  | "location.ping"
  | "amc.sell_onsite"

/**
 * "stuck" = failed `MAX_ATTEMPTS_BEFORE_STUCK` times (see sync.ts) and no
 * longer auto-retried; it still needs a technician/admin to look at it, it
 * has NOT been dropped (see sync.ts's file-level comment on that guarantee).
 */
export type OutboxStatus = "pending" | "syncing" | "failed" | "stuck"

export interface OutboxJob {
  id?: number
  kind: OutboxKind
  /** Client-generated id so dependent jobs (e.g. sop_step referencing a visit created offline) can chain before the server id exists. */
  clientRefId?: string
  payload: unknown
  status: OutboxStatus
  attempts: number
  lastError?: string
  /** Timestamp of the job's first failure (set once, kept across retries) — lets the UI show "failing since …" instead of just an attempt count. */
  firstFailedAt?: number
  /** Earliest time (ms epoch) this job is eligible to be retried again — backoff scheduling (sync.ts). Undefined means "eligible now", which is also true for every job that has never failed, so the happy path is unaffected. */
  nextRetryAt?: number
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
  kind: "before" | "after" | "selfie" | "signature_tech" | "signature_admin" | "signature_customer" | "voice_note"
  dataUrl: string
  meta?: { lat?: number; lng?: number; capturedAt: string }
  createdAt: number
}

export interface CachedSettings {
  orgId: string
  data: unknown
  updatedAt: number
}

/** Local mirror of the signed-in technician's own `technicians` row, keyed by profile id — same read-through-cache shape as CachedSettings, so a cold app load while offline (phone restart, killed PWA) resolves to the last-known row instead of a hard failure. */
export interface CachedTechnician {
  profileId: string
  data: unknown
  updatedAt: number
}

/**
 * On-device draft of the TECH-07 on-site stepper's own form state — SOP
 * checklist items, spares picked, charges/discount typed, RO checklist
 * fields, photos, signatures, payment fields, which step the technician was
 * on, etc. This is distinct from `DraftVisit` (which only ever held the
 * visit-creation row) and from the outbox (write-and-forget job payloads,
 * never read back into the UI): most of these fields have no server
 * representation at all until their section's own explicit save button is
 * tapped, so without a local copy they simply vanish on navigating away and
 * back. One row per ticket — matches "one open visit per ticket".
 */
export interface VisitFormDraft {
  ticketId: string
  visitId: string | null
  data: Record<string, unknown>
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
  visitFormDrafts: EntityTable<VisitFormDraft, "ticketId">
  technicianCache: EntityTable<CachedTechnician, "profileId">
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

// Only the new/changed table needs listing — v1's tables carry over as-is.
db.version(2).stores({
  visitFormDrafts: "ticketId",
})

// v3 adds a `nextRetryAt` index to `outbox` for backoff scheduling (sync.ts)
// and the "stuck" status value (status was already indexed, so a new value
// for it needs no schema change). This is purely additive: existing rows in
// an already-installed client's IndexedDB simply have `nextRetryAt`
// undefined, which retry logic treats as "eligible immediately" — matching
// today's behavior for anything that hasn't failed yet — and Dexie doesn't
// require a data migration for a new optional/index field. No existing rows
// or tables are touched.
db.version(3).stores({
  outbox: "++id, kind, status, createdAt, nextRetryAt",
})

// v4 adds technicianCache — read-through cache for getMyTechnician (own
// technician row), same shape/purpose as settingsCache above. Purely
// additive new table; nothing else changes.
db.version(4).stores({
  technicianCache: "profileId",
})

export { db }
