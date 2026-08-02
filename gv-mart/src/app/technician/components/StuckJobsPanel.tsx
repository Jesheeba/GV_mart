import { useTranslation } from "react-i18next"
import { AlertTriangle, X } from "lucide-react"
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog"
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
    <Dialog open onOpenChange={(open) => { if (!open) onClose() }}>
      <DialogContent showClose={false} className="max-w-sm">
        <div className="flex items-start justify-between gap-3 border-b border-border pb-3">
          <div className="min-w-0">
            <DialogTitle className="flex items-center gap-1.5 pr-0 text-danger">
              <AlertTriangle className="size-4" />
              {t("technician.sync.stuckPanelTitle", { count: jobs.length })}
            </DialogTitle>
            <DialogDescription>{t("technician.sync.stuckPanelDescription")}</DialogDescription>
          </div>
          <Button type="button" variant="ghost" size="icon-sm" onClick={onClose} aria-label={t("technician.sync.close")}>
            <X className="size-4" />
          </Button>
        </div>
        <div className="flex max-h-80 flex-col gap-2.5 overflow-y-auto">
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
        </div>
      </DialogContent>
    </Dialog>
  )
}
