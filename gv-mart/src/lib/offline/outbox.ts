import { db, type OutboxJob, type OutboxKind } from "./db"
import { OUTBOX_PAYLOAD_VERSION } from "./outboxContract"

/**
 * Queues a mutation for sync. Returns the local outbox row id (not a server
 * id). Tags the JOB (not the payload — several kinds spread `payload`
 * verbatim into a Supabase insert/upsert, so a stray field inside it would
 * try to write a non-existent column) with `payloadVersion`, see
 * outboxContract.ts. Purely for triage, never branched on by the replayer:
 * the additive-only rule means every version's required fields are a
 * superset of every earlier version's, so a job tagged `payloadVersion: 1`
 * and a job with no tag at all (queued before this field existed) both
 * replay through the exact same code path.
 */
export async function enqueue(kind: OutboxKind, payload: unknown, clientRefId?: string) {
  const now = Date.now()
  const job: OutboxJob = {
    kind,
    clientRefId,
    payload,
    payloadVersion: OUTBOX_PAYLOAD_VERSION,
    status: "pending",
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  }
  return db.outbox.add(job)
}

/** Jobs still in the normal retry rotation (never failed, or failed but still under the backoff/attempt threshold in sync.ts). */
export function pendingCount() {
  return db.outbox.where("status").anyOf(["pending", "failed"]).count()
}

/**
 * The still-unsynced `service_visit.start` job for this visit, if any —
 * existence alone means the row doesn't exist on the server yet (a synced
 * job is deleted from the outbox, see sync.ts's flushOutbox), regardless of
 * whether it's pending/failed/stuck. Lets a caller (OnSiteVisitPage's OTP
 * step) tell "not synced yet" apart from "synced, something else is wrong"
 * before attempting a live round-trip that would otherwise fail with an
 * unhelpful "visit not found".
 */
export async function getPendingStartVisitJob(visitId: string) {
  const jobs = await db.outbox.where("kind").equals("service_visit.start").toArray()
  return jobs.find((job) => (job.payload as { id?: string } | null)?.id === visitId)
}

/** Jobs that gave up auto-retrying after too many failures — see sync.ts's MAX_ATTEMPTS_BEFORE_STUCK. Not dropped, just no longer retried unattended. */
export function stuckCount() {
  return db.outbox.where("status").equals("stuck").count()
}

export function watchPendingCount(cb: (count: number) => void) {
  let cancelled = false
  async function poll() {
    if (cancelled) return
    cb(await pendingCount())
  }
  const handle = setInterval(poll, 3000)
  void poll()
  return () => {
    cancelled = true
    clearInterval(handle)
  }
}

export function watchStuckCount(cb: (count: number) => void) {
  let cancelled = false
  async function poll() {
    if (cancelled) return
    cb(await stuckCount())
  }
  const handle = setInterval(poll, 3000)
  void poll()
  return () => {
    cancelled = true
    clearInterval(handle)
  }
}

/** Full job detail for the "stuck jobs" panel — what kind of action it was and when it started failing, so the technician has enough to act on. */
export function watchStuckJobs(cb: (jobs: OutboxJob[]) => void) {
  let cancelled = false
  async function poll() {
    if (cancelled) return
    const jobs = await db.outbox.where("status").equals("stuck").sortBy("createdAt")
    cb(jobs)
  }
  const handle = setInterval(poll, 3000)
  void poll()
  return () => {
    cancelled = true
    clearInterval(handle)
  }
}

/**
 * Technician-initiated retry for a stuck job: puts it back in the normal
 * "pending" rotation with no backoff delay, so the next flush pass picks it
 * up right away. `attempts`/`lastError`/`firstFailedAt` are left as-is (not
 * reset) so its failure history is still visible if it gets stuck again —
 * this is a fresh chance, not a clean slate.
 */
export function retryStuckJob(id: number) {
  return db.outbox.update(id, {
    status: "pending",
    nextRetryAt: undefined,
    updatedAt: Date.now(),
  })
}
