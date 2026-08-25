// Admin-configurable pacing for the WhatsApp cron-backed Edge Functions —
// see 20260825160000_wa_scheduled_job_intervals.sql. GitHub Actions fires
// both wa-milestone-dispatch and wa-scheduled-tasks on a tight, fixed
// schedule; this is what actually decides whether a given org's real work
// runs on a given invocation, per org (settings is one row per org).
//
// A settings-read failure or a missing settings row fails OPEN (runs
// anyway) — this gate is a pacing optimization, not a safety mechanism.
// The real protection against double-sends is each job's own dedupe logic
// (wa_message_id/retried_at checks, alreadySentRecently) — unchanged by
// this file.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export type ScheduledJobKey = "milestone_dispatch" | "scheduled_tasks"

export async function shouldRunJob(admin: SupabaseClient, orgId: string, job: ScheduledJobKey): Promise<boolean> {
  const { data, error } = await admin
    .from("settings")
    .select(`${job}_enabled, ${job}_interval_minutes, ${job}_last_run_at`)
    .eq("org_id", orgId)
    .maybeSingle()

  if (error) {
    console.error(`wa-job-pacing: settings lookup failed for ${job}, running anyway`, error)
    return true
  }
  if (!data) return true // no settings row for this org yet — don't block on it

  const row = data as Record<string, unknown>
  if (row[`${job}_enabled`] === false) return false

  const lastRunAt = row[`${job}_last_run_at`] as string | null
  if (!lastRunAt) return true

  const intervalMinutes = (row[`${job}_interval_minutes`] as number | null) ?? 0
  return Date.now() - new Date(lastRunAt).getTime() >= intervalMinutes * 60_000
}

export async function markJobRan(admin: SupabaseClient, orgId: string, job: ScheduledJobKey): Promise<void> {
  const { error } = await admin
    .from("settings")
    .update({ [`${job}_last_run_at`]: new Date().toISOString() })
    .eq("org_id", orgId)
  if (error) console.error(`wa-job-pacing: failed to update ${job}_last_run_at`, error)
}
