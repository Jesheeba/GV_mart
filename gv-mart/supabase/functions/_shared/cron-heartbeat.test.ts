// Plain-Node check of checkAndAlertStaleJobs with a fake Supabase client (no network, no Deno needed):
//   npx tsx supabase/functions/_shared/cron-heartbeat.test.ts
// Exits non-zero on any failure.
import { checkAndAlertStaleJobs } from "./cron-heartbeat.ts"

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
        insert: async (r: Record<string, unknown>) => { inserts.push(r); return { error: null } },
        upsert: async (r: Record<string, unknown>) => { upserts.push(r); return { error: null } },
      }
    },
  }
  return { client: client as never, inserts, upserts }
}

const healthy = (key: string, ageMs: number): Row => ({ job_key: key, last_run_at: ago(ageMs), last_status: "ok", last_error: null, last_stale_alert_at: null })
const baseline = () => [healthy("wa_scheduled_tasks", HOUR), healthy("wa_milestone_dispatch", MIN), healthy("technician_shift_reset", HOUR)]

let failures = 0
function check(name: string, ok: boolean, info = "") {
  console.log((ok ? "PASS  " : "FAIL  ") + name + (info ? "  [" + info + "]" : ""))
  if (!ok) failures++
}

async function run(extra: Row[]) {
  const f = fakeAdmin([...baseline(), ...extra])
  await checkAndAlertStaleJobs(f.client)
  return f
}

const lead = (r: Partial<Row>): Row => ({ job_key: "lead_followup_notifications", last_run_at: ago(2 * MIN), last_status: "ok", last_error: null, last_stale_alert_at: null, ...r })

;(async () => {
  let f = await run([lead({})])
  check("lead job ticked 2 minutes ago: no alert", f.inserts.length === 0)

  f = await run([lead({ last_run_at: ago(14 * MIN) })])
  check("14 minutes: still inside the 15-minute window, no alert", f.inserts.length === 0)

  f = await run([lead({ last_run_at: ago(20 * MIN) })])
  check("20 minutes quiet: one master cron_job_stale alert per organisation", f.inserts.length === 2 && f.inserts.every((i) => i.role === "master" && i.type === "cron_job_stale"), String(f.inserts.length))
  check("alert names the job and shows minutes, not '0h'", String(f.inserts[0]?.body).includes("lead_followup_notifications: last ran 20m ago, expected every 5m"), String(f.inserts[0]?.body))
  check("alert marks last_stale_alert_at so it does not repeat for 6h", f.upserts.some((u) => u.job_key === "lead_followup_notifications" && typeof u.last_stale_alert_at === "string"))

  f = await run([lead({ last_run_at: ago(40 * MIN), last_stale_alert_at: ago(1 * HOUR) })])
  check("already alerted 1h ago: no repeat alert", f.inserts.length === 0)

  f = await run([lead({ last_run_at: ago(40 * MIN), last_stale_alert_at: ago(7 * HOUR) })])
  check("alerted 7h ago and still quiet: alerts again", f.inserts.length === 2)

  f = await run([lead({ last_run_at: ago(3 * HOUR) })])
  check("3 hours quiet reads as hours", String(f.inserts[0]?.body).includes("last ran 3h ago"), String(f.inserts[0]?.body))

  f = await run([])
  check("no heartbeat row at all: 'has never recorded a completed run'", f.inserts.length === 2 && String(f.inserts[0]?.body).includes("lead_followup_notifications: has never recorded a completed run"))

  f = await run([lead({ last_status: "error", last_error: "relation does not exist" })])
  check("recent run that FAILED alerts with the error text", f.inserts.length === 2 && String(f.inserts[0]?.body).includes("last run failed: relation does not exist"))

  f = await run([lead({ last_run_at: ago(20 * MIN) }), { job_key: "wa_milestone_dispatch", last_run_at: ago(1 * HOUR), last_status: "ok", last_error: null, last_stale_alert_at: null }])
  check("two stale jobs are reported in ONE notification per organisation", f.inserts.length === 2 && String(f.inserts[0]?.title).includes("2 cron jobs"), String(f.inserts[0]?.title))

  console.log(failures === 0 ? "ALL PASSED" : failures + " FAILED")
  process.exit(failures === 0 ? 0 : 1)
})()
