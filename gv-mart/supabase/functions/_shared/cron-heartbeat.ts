// Production-readiness audit 2026-09-23, Item 3. See
// 20260924110000_cron_job_heartbeats.sql for why this exists: per-task
// errors inside the three GH-Actions-driven cron functions were silently
// swallowed (console.error, still HTTP 200), and nothing ever checked
// whether the cron trigger itself had stopped firing at all.
//
// Two halves:
//   - recordHeartbeat: every cron function calls this once, at the end of
//     its own run, success or failure. Cheap, always safe to call.
//   - checkAndAlertStaleJobs: called by all three functions on every
//     invocation (unconditionally, before any pacing gate) so that as long
//     as ANY ONE of the three GH Actions schedules is still firing, it will
//     notice the other two going stale. All three failing at once (e.g. a
//     repo-wide secret rotation gone wrong) is a real residual gap this
//     can't close — that would need an external dead-man's-switch service,
//     which this project has deliberately avoided adding (see
//     wa-scheduled-tasks/index.ts's header on avoiding new infra).
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export type CronJobKey = "wa_scheduled_tasks" | "wa_milestone_dispatch" | "technician_shift_reset"

// Expected interval per job. wa-scheduled-tasks and wa-milestone-dispatch
// are ALSO admin-configurable per org (settings.*_interval_minutes) for
// pacing real work — this is deliberately a fixed, coarser figure for
// staleness detection only, matching each job's GitHub Actions trigger
// cadence (see .github/workflows/*.yml), not the per-org pacing value.
const EXPECTED_INTERVAL_MINUTES: Record<CronJobKey, number> = {
  wa_scheduled_tasks: 24 * 60, // daily
  wa_milestone_dispatch: 5,
  technician_shift_reset: 24 * 60, // daily
}

// How far past its expected interval a job has to be before it's "stale"
// (avoids alerting on a normal few-minutes GH Actions scheduling jitter),
// and how long to wait before re-alerting on the same still-stale job so a
// multi-day outage doesn't spam a notification every 5 minutes.
const STALE_MULTIPLIER = 3
const RE_ALERT_AFTER_HOURS = 6

export async function recordHeartbeat(admin: SupabaseClient, jobKey: CronJobKey, status: "ok" | "error", error?: string): Promise<void> {
  const { error: upsertErr } = await admin.from("cron_job_heartbeats").upsert(
    {
      job_key: jobKey,
      last_run_at: new Date().toISOString(),
      last_status: status,
      last_error: status === "error" ? (error ?? "unknown error") : null,
      // A healthy run clears any previous stale-alert cooldown, so a future
      // new staleness episode (not just the tail of the current one) alerts again.
      ...(status === "ok" ? { last_stale_alert_at: null } : {}),
    },
    { onConflict: "job_key" }
  )
  if (upsertErr) console.error("cron-heartbeat: failed to record heartbeat for", jobKey, upsertErr)
}

export async function checkAndAlertStaleJobs(admin: SupabaseClient): Promise<void> {
  const { data: heartbeats, error } = await admin.from("cron_job_heartbeats").select("job_key, last_run_at, last_status, last_error, last_stale_alert_at")
  if (error) {
    console.error("cron-heartbeat: could not read heartbeats", error)
    return
  }
  const byKey = new Map((heartbeats ?? []).map((h) => [h.job_key as CronJobKey, h]))
  const now = Date.now()

  const staleJobs: { jobKey: CronJobKey; reason: string }[] = []
  for (const jobKey of Object.keys(EXPECTED_INTERVAL_MINUTES) as CronJobKey[]) {
    const heartbeat = byKey.get(jobKey)
    const staleAfterMs = EXPECTED_INTERVAL_MINUTES[jobKey] * STALE_MULTIPLIER * 60_000
    if (!heartbeat || !heartbeat.last_run_at) {
      staleJobs.push({ jobKey, reason: "has never recorded a completed run" })
      continue
    }
    const ageMs = now - new Date(heartbeat.last_run_at).getTime()
    if (ageMs > staleAfterMs) {
      const ageHours = Math.round(ageMs / 3_600_000)
      staleJobs.push({ jobKey, reason: `last ran ${ageHours}h ago, expected every ${EXPECTED_INTERVAL_MINUTES[jobKey]}m` })
      continue
    }
    if (heartbeat.last_status === "error") {
      // Only alert once per cooldown window for a still-erroring-but-still-firing job.
      const lastAlerted = heartbeat.last_stale_alert_at ? new Date(heartbeat.last_stale_alert_at).getTime() : 0
      if (now - lastAlerted > RE_ALERT_AFTER_HOURS * 3_600_000) {
        staleJobs.push({ jobKey, reason: `still firing but its last run failed: ${heartbeat.last_error ?? "unknown error"}` })
      }
    }
  }
  if (staleJobs.length === 0) return

  // Don't re-alert on a job already flagged within the cooldown window.
  const toAlert = staleJobs.filter((s) => {
    const heartbeat = byKey.get(s.jobKey)
    const lastAlerted = heartbeat?.last_stale_alert_at ? new Date(heartbeat.last_stale_alert_at).getTime() : 0
    return now - lastAlerted > RE_ALERT_AFTER_HOURS * 3_600_000
  })
  if (toAlert.length === 0) return

  const { data: orgs, error: orgsError } = await admin.from("organizations").select("id")
  if (orgsError) {
    console.error("cron-heartbeat: could not load orgs to alert", orgsError)
    return
  }
  const title = toAlert.length === 1 ? `Cron job "${toAlert[0].jobKey}" looks stuck` : `${toAlert.length} cron jobs look stuck`
  const body = toAlert.map((s) => `${s.jobKey}: ${s.reason}`).join("\n")
  for (const org of orgs ?? []) {
    await admin.from("notifications").insert({
      org_id: org.id,
      role: "master",
      type: "cron_job_stale",
      title,
      body,
    })
  }
  for (const stale of toAlert) {
    await admin.from("cron_job_heartbeats").upsert(
      { job_key: stale.jobKey, last_stale_alert_at: new Date().toISOString() },
      { onConflict: "job_key" }
    )
  }
}
