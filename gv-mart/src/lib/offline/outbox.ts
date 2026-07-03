import { db, type OutboxJob, type OutboxKind } from "./db"

/** Queues a mutation for sync. Returns the local outbox row id (not a server id). */
export async function enqueue(kind: OutboxKind, payload: unknown, clientRefId?: string) {
  const now = Date.now()
  const job: OutboxJob = {
    kind,
    clientRefId,
    payload,
    status: "pending",
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  }
  return db.outbox.add(job)
}

export function pendingCount() {
  return db.outbox.where("status").anyOf(["pending", "failed"]).count()
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
