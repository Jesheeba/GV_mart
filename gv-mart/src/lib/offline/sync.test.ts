import { beforeEach, describe, expect, it, vi } from "vitest"
import type { OutboxJob } from "./db"

/**
 * Fix for the missing-service_visits-row investigation (2026-11-11): a
 * technician's photo/signature steps (`service_visit.arrive`,
 * `service_visit.image`) are queued `.update()` calls that Supabase reports
 * as "success" even when zero rows matched — e.g. because the visit's own
 * `service_visit.start` INSERT hasn't synced yet. That silently drops the
 * patch instead of retrying once the row exists. These tests cover the fix
 * (runJob throws on zero rows updated) and the queue-ordering helper that
 * backs flushOutbox's retry loop.
 */

type FromCall = { table: string; calls: { method: string; args: unknown[] }[] }
const fromCalls: FromCall[] = []
let responses: Record<string, { data: unknown; error: unknown }> = {}

function makeBuilder(table: string): unknown {
  const record: FromCall = { table, calls: [] }
  fromCalls.push(record)
  const resolve = () => responses[table] ?? { data: null, error: null }
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") return (res: (v: unknown) => void) => res(resolve())
      return (...args: unknown[]) => {
        record.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: (table: string) => makeBuilder(table),
    rpc: vi.fn(),
  },
}))

vi.mock("@/services/whatsapp", () => ({
  triggerWaDispatchNow: vi.fn(),
}))

import { runJob, selectDueJobs } from "./sync"

beforeEach(() => {
  fromCalls.length = 0
  responses = {}
})

function job(overrides: Partial<OutboxJob>): OutboxJob {
  return { kind: "service_visit.arrive", payload: {}, status: "pending", attempts: 0, createdAt: 0, updatedAt: 0, ...overrides }
}

describe("runJob — zero-rows-updated detection (missing service_visits row fix)", () => {
  it("service_visit.arrive throws when the visit row doesn't exist yet (zero rows updated)", async () => {
    responses.service_visits = { data: [], error: null }
    const j = job({ kind: "service_visit.arrive", payload: { visitId: "visit-1", patch: { notes: "x" } } })
    await expect(runJob(j)).rejects.toThrow(/zero rows updated/)
  })

  it("service_visit.arrive succeeds when a row was actually matched", async () => {
    responses.service_visits = { data: [{ id: "visit-1" }], error: null }
    const j = job({ kind: "service_visit.arrive", payload: { visitId: "visit-1", patch: { notes: "x" } } })
    await expect(runJob(j)).resolves.toBeUndefined()
  })

  it("service_visit.image throws when the visit row doesn't exist yet (zero rows updated)", async () => {
    responses.service_visits = { data: [], error: null }
    const j = job({ kind: "service_visit.image", payload: { visitId: "visit-1", column: "before_image_url", url: "https://x/y.jpg" } })
    await expect(runJob(j)).rejects.toThrow(/zero rows updated/)
  })

  it("service_visit.image succeeds when a row was actually matched", async () => {
    responses.service_visits = { data: [{ id: "visit-1" }], error: null }
    const j = job({ kind: "service_visit.image", payload: { visitId: "visit-1", column: "before_image_url", url: "https://x/y.jpg" } })
    await expect(runJob(j)).resolves.toBeUndefined()
  })

  it("still surfaces a genuine Supabase error (e.g. RLS) ahead of the zero-rows check", async () => {
    responses.service_visits = { data: null, error: { message: "permission denied" } }
    const j = job({ kind: "service_visit.image", payload: { visitId: "visit-1", column: "before_image_url", url: "https://x/y.jpg" } })
    await expect(runJob(j)).rejects.toMatchObject({ message: "permission denied" })
  })
})

describe("selectDueJobs — outbox replay ordering", () => {
  it("keeps jobs that have never failed (no nextRetryAt) in their given (createdAt) order", () => {
    const jobs = [job({ createdAt: 1 }), job({ createdAt: 2 }), job({ createdAt: 3 })]
    expect(selectDueJobs(jobs, 1000)).toEqual(jobs)
  })

  it("excludes a failed job still inside its backoff window", () => {
    const stillWaiting = job({ createdAt: 1, nextRetryAt: 5000 })
    const dueNow = job({ createdAt: 2, nextRetryAt: 500 })
    const neverFailed = job({ createdAt: 3 })
    expect(selectDueJobs([stillWaiting, dueNow, neverFailed], 1000)).toEqual([dueNow, neverFailed])
  })

  it("preserves relative order among the jobs that are due, so a visit's start insert is always replayed before its later patches", () => {
    const start = job({ kind: "service_visit.start", createdAt: 1 })
    const arrive = job({ kind: "service_visit.arrive", createdAt: 2 })
    const image = job({ kind: "service_visit.image", createdAt: 3 })
    expect(selectDueJobs([start, arrive, image], 1000).map((j) => j.kind)).toEqual(["service_visit.start", "service_visit.arrive", "service_visit.image"])
  })
})
