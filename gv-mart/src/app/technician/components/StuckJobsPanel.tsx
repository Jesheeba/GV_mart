import { useTranslation } from "react-i18next"
import { AlertTriangle, X } from "lucide-react"
import { Card, CardHeader, CardTitle, CardDescription, CardAction, CardContent } from "@/components/ui/card"
import { Button } from "@/components/ui/button"
import type { OutboxJob } from "@/lib/offline/db"

/**
 * Small expandable panel opened from the sync-status chip when one or more
 * outbox jobs are `stuck` (failed MAX_ATTEMPTS_BEFORE_STUCK times — see
 * sync.ts). Shows enough per job to be useful (what kind of action, when it
 * started failing, the last error) and a manual retry action — stuck never
 * means "deleted", so this is the technician's way to give a job another go.
 */
export function StuckJobsPanel({
  jobs,
  onRetry,
  onClose,
}: {
  jobs: OutboxJob[]
  onRetry: (id: number) => void
  onClose: () => void
}) {
  const { t } = useTranslation()

  return (
    <div className="fixed inset-0 z-50" role="presentation" onClick={onClose}>
      <div
        className="absolute inset-x-4 top-16 mx-auto max-w-sm"
        onClick={(e) => e.stopPropagation()}
      >
        <Card>
          <CardHeader className="border-b border-border pb-4">
            <CardTitle className="flex items-center gap-1.5 text-danger">
              <AlertTriangle className="size-4" />
              {t("technician.sync.stuckPanelTitle", { count: jobs.length })}
            </CardTitle>
            <CardDescription>{t("technician.sync.stuckPanelDescription")}</CardDescription>
            <CardAction>
              <Button type="button" variant="ghost" size="icon-sm" onClick={onClose} aria-label={t("technician.sync.close")}>
                <X className="size-4" />
              </Button>
            </CardAction>
          </CardHeader>
          <CardContent className="flex max-h-80 flex-col gap-2.5 overflow-y-auto">
            {jobs.length === 0 ? (
              <p className="py-2 text-sm text-text-muted">{t("technician.sync.stuckPanelEmpty")}</p>
            ) : (
              jobs.map((job) => (
                <div key={job.id} className="flex items-center justify-between gap-3 rounded-lg border border-border p-3">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-text">
                      {t(`technician.sync.jobKind.${job.kind}`)}
                    </p>
                    <p className="text-xs text-text-muted">
                      {t("technician.sync.failingSince", {
                        time: new Date(job.firstFailedAt ?? job.updatedAt).toLocaleString(),
                      })}
                    </p>
                    {job.lastError ? <p className="mt-0.5 truncate text-xs text-danger">{job.lastError}</p> : null}
                  </div>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() => job.id != null && onRetry(job.id)}
                  >
                    {t("common.retry")}
                  </Button>
                </div>
              ))
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
