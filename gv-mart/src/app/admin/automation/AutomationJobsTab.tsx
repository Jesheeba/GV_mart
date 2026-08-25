import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import type { TablesUpdate } from "@/types/database"

type JobKey = "milestone_dispatch" | "scheduled_tasks"

function timeAgo(iso: string | null, locale: string): string {
  if (!iso) return ""
  const ms = Date.now() - new Date(iso).getTime()
  const minutes = Math.max(0, Math.round(ms / 60_000))
  if (minutes < 1) return locale === "ta" ? "இப்போது தான்" : "just now"
  if (minutes < 60) return `${minutes}m`
  const hours = Math.round(minutes / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.round(hours / 24)}d`
}

/** GitHub Actions triggers wa-milestone-dispatch/wa-scheduled-tasks on a
 * tight, fixed cron (see the .github/workflows files) — this tab edits
 * what actually governs how often each does real work per org
 * (settings.{job}_enabled / {job}_interval_minutes), read at the top of
 * each function via _shared/wa-job-pacing.ts. */
export function AutomationJobsTab() {
  const { t, i18n } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)

  if (isLoading || !settings) {
    return (
      <div className="space-y-3">
        <div className="h-28 animate-pulse rounded-card bg-surface-alt" />
        <div className="h-28 animate-pulse rounded-card bg-surface-alt" />
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <p className="text-xs text-text-muted">{t("automation.jobs.hint")}</p>
      <JobCard
        jobKey="milestone_dispatch"
        title={t("automation.jobs.milestoneDispatch.title")}
        description={t("automation.jobs.milestoneDispatch.description")}
        enabled={settings.milestone_dispatch_enabled}
        intervalMinutes={settings.milestone_dispatch_interval_minutes}
        lastRunAt={settings.milestone_dispatch_last_run_at}
        locale={i18n.language}
        onSave={(patch) => updateMut.mutate(patch)}
        saving={updateMut.isPending}
      />
      <JobCard
        jobKey="scheduled_tasks"
        title={t("automation.jobs.scheduledTasks.title")}
        description={t("automation.jobs.scheduledTasks.description")}
        enabled={settings.scheduled_tasks_enabled}
        intervalMinutes={settings.scheduled_tasks_interval_minutes}
        lastRunAt={settings.scheduled_tasks_last_run_at}
        locale={i18n.language}
        onSave={(patch) => updateMut.mutate(patch)}
        saving={updateMut.isPending}
      />
    </div>
  )
}

function JobCard({
  jobKey,
  title,
  description,
  enabled,
  intervalMinutes,
  lastRunAt,
  locale,
  onSave,
  saving,
}: {
  jobKey: JobKey
  title: string
  description: string
  enabled: boolean
  intervalMinutes: number
  lastRunAt: string | null
  locale: string
  onSave: (patch: TablesUpdate<"settings">) => void
  saving: boolean
}) {
  const { t } = useTranslation()
  const [localEnabled, setLocalEnabled] = useState(enabled)
  const [localInterval, setLocalInterval] = useState(intervalMinutes)

  useEffect(() => {
    setLocalEnabled(enabled)
    setLocalInterval(intervalMinutes)
  }, [enabled, intervalMinutes])

  const dirty = localEnabled !== enabled || localInterval !== intervalMinutes

  return (
    <Card className="gap-3">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h3 className="text-sm font-semibold text-text">{title}</h3>
          <p className="text-xs text-text-muted">{description}</p>
        </div>
        <span className="text-xs text-text-muted">
          {t("automation.jobs.lastRun")}: {lastRunAt ? `${timeAgo(lastRunAt, locale)} ${locale === "ta" ? "முன்பு" : "ago"}` : t("automation.jobs.never")}
        </span>
      </div>

      <div className="flex flex-wrap items-end gap-3">
        <label className="flex items-center gap-2.5 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm text-text">
          <input type="checkbox" className="size-4 accent-accent" checked={localEnabled} onChange={(e) => setLocalEnabled(e.target.checked)} />
          <span className="font-medium">{t("automation.jobs.enabled")}</span>
        </label>

        <div className="space-y-1">
          <Label htmlFor={`${jobKey}-interval`}>{t("automation.jobs.intervalMinutes")}</Label>
          <Input
            id={`${jobKey}-interval`}
            type="number"
            min={1}
            step={1}
            value={localInterval}
            onChange={(e) => setLocalInterval(Math.max(1, Number(e.target.value) || 1))}
            className="w-32"
          />
        </div>

        <Button
          type="button"
          disabled={!dirty || saving}
          onClick={() =>
            onSave({
              [`${jobKey}_enabled`]: localEnabled,
              [`${jobKey}_interval_minutes`]: localInterval,
            })
          }
        >
          {saving ? <Loader2 className="size-4 animate-spin" /> : t("automation.jobs.save")}
        </Button>
      </div>
    </Card>
  )
}
