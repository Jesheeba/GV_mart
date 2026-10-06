import { describe, expect, it } from "vitest"
import { checkAndAlertStaleJobs } from "./cron-heartbeat"

// checkAndAlertStaleJobs with a fake Supabase client (no network). Covers the pg_cron
// 'lead_followup_notifications' dead-man's switch added in migration 20261008140000.

type Row = { job_key: string; last_run_at: string | null; last_status: "ok" | "error"; last_error: string | null; last_stale_alert_at: string | null }
const ago = (ms: number) => new Date(Date.now() - ms).toISOString()
const MIN = 60_000
const HOUR = 3_600_000

function fakeAdmin(rows: Row[]) {
  const inserts: Record<string, unknown>[] = []
  const upserts: Record<string, unknown>[] = []
  const client = {
    from(table: string) {
      return {
        select: async () => ({ data: table === "cron_job_heartbeats" ? rows : [{ id: "org-1" }, { id: "org-2" }], error: null }),
        insert: async (r: Record<string, unknown>) => {
          inserts.push(r)
          return { error: null }
        },
        upsert: async (r: Record<string, unknown>) => {
          upserts.push(r)
          return { error: null }
        },
      }
    },
  }
  return { client: client as never, inserts, upserts }
}

const healthy = (key: string, ageMs: number): Row => ({ job_key: key, last_run_at: ago(ageMs), last_status: "ok", last_error: null, last_stale_alert_at: null })
const baseline = () => [healthy("wa_scheduled_tasks", HOUR), healthy("wa_milestone_dispatch", MIN), healthy("technician_shift_reset", HOUR)]
const lead = (r: Partial<Row>): Row => ({ job_key: "lead_followup_notifications", last_run_at: ago(2 * MIN), last_status: "ok", last_error: null, last_stale_alert_at: null, ...r })

async function run(extra: Row[]) {
  const f = fakeAdmin([...baseline(), ...extra])
  await checkAndAlertStaleJobs(f.client)
  return f
}

describe("checkAndAlertStaleJobs: lead_followup_notifications (pg_cron, expected every 5 minutes)", () => {
  it("does not alert when it ticked 2 minutes ago", async () => {
    expect((await run([lead({})])).inserts).toHaveLength(0)
  })

  it("does not alert inside the 15-minute window", async () => {
    expect((await run([lead({ last_run_at: ago(14 * MIN) })])).inserts).toHaveLength(0)
  })

  it("alerts master once per organisation after 20 minutes of silence, naming the job in minutes", async () => {
    const f = await run([lead({ last_run_at: ago(20 * MIN) })])
    expect(f.inserts).toHaveLength(2)
    expect(f.inserts.every((i) => i.role === "master" && i.type === "cron_job_stale")).toBe(true)
    expect(String(f.inserts[0].body)).toContain("lead_followup_notifications: last ran 20m ago, expected every 5m")
    expect(f.upserts.some((u) => u.job_key === "lead_followup_notifications" && typeof u.last_stale_alert_at === "string")).toBe(true)
  })

  it("does not repeat within the 6-hour cooldown, and alerts again after it", async () => {
    expect((await run([lead({ last_run_at: ago(40 * MIN), last_stale_alert_at: ago(1 * HOUR) })])).inserts).toHaveLength(0)
    expect((await run([lead({ last_run_at: ago(40 * MIN), last_stale_alert_at: ago(7 * HOUR) })])).inserts).toHaveLength(2)
  })

  it("reads as hours once it has been quiet for more than two hours", async () => {
    const f = await run([lead({ last_run_at: ago(3 * HOUR) })])
    expect(String(f.inserts[0].body)).toContain("last ran 3h ago")
  })

  it("reports 'never recorded a completed run' when there is no heartbeat row", async () => {
    const f = await run([])
    expect(f.inserts).toHaveLength(2)
    expect(String(f.inserts[0].body)).toContain("lead_followup_notifications: has never recorded a completed run")
  })

  it("alerts with the error text when the latest tick failed", async () => {
    const f = await run([lead({ last_status: "error", last_error: "relation does not exist" })])
    expect(f.inserts).toHaveLength(2)
    expect(String(f.inserts[0].body)).toContain("last run failed: relation does not exist")
  })

  it("combines two stale jobs into one notification per organisation", async () => {
    const f = await run([lead({ last_run_at: ago(20 * MIN) }), healthy("wa_milestone_dispatch", 1 * HOUR)])
    expect(f.inserts).toHaveLength(2)
    expect(String(f.inserts[0].title)).toContain("2 cron jobs")
  })
})
