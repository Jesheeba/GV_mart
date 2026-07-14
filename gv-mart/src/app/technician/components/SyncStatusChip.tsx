import { useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle, CloudOff, Loader2, RefreshCw } from "lucide-react"
import { useOnlineStatus } from "@/hooks/useOnlineStatus"
import { useStuckJobs, useSyncStatus } from "@/hooks/useTechnician"
import { retryStuckJob } from "@/lib/offline/outbox"
import { cn } from "@/lib/utils"
import { StuckJobsPanel } from "./StuckJobsPanel"

/**
 * Small always-visible status chip: offline / syncing / N pending / synced
 * (Phase 7 offline-first requirement made visible to the technician) — plus
 * a distinct red "stuck" state (jobs that failed repeatedly and stopped
 * auto-retrying, see sync.ts's MAX_ATTEMPTS_BEFORE_STUCK) that opens a panel
 * with enough detail to act on, so a job silently failing for hours doesn't
 * look the same as one about to sync on the next tick.
 */
export function SyncStatusChip() {
  const { t } = useTranslation()
  const online = useOnlineStatus()
  const { pending, syncing } = useSyncStatus()
  const stuckJobs = useStuckJobs()
  const [panelOpen, setPanelOpen] = useState(false)

  let chip: ReactNode
  if (stuckJobs.length > 0) {
    chip = (
      <button
        type="button"
        onClick={() => setPanelOpen(true)}
        className="inline-flex items-center gap-1 rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger"
      >
        <AlertTriangle className="size-3" />
        {t("technician.sync.stuck", { count: stuckJobs.length })}
      </button>
    )
  } else if (!online) {
    chip = (
      <span className="inline-flex items-center gap-1 rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
        <CloudOff className="size-3" />
        {t("technician.sync.offline")}
      </span>
    )
  } else if (syncing || pending > 0) {
    chip = (
      <span className={cn("inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium", syncing ? "bg-info/10 text-info" : "bg-warning/10 text-warning")}>
        {syncing ? <Loader2 className="size-3 animate-spin" /> : <RefreshCw className="size-3" />}
        {syncing ? t("technician.sync.syncing") : t("technician.sync.pending", { count: pending })}
      </span>
    )
  } else {
    chip = (
      <span className="inline-flex items-center gap-1 rounded-full bg-success/10 px-2.5 py-1 text-xs font-medium text-success">
        {t("technician.sync.synced")}
      </span>
    )
  }

  return (
    <>
      {chip}
      {panelOpen ? (
        <StuckJobsPanel
          jobs={stuckJobs}
          onRetry={(id) => void retryStuckJob(id)}
          onClose={() => setPanelOpen(false)}
        />
      ) : null}
    </>
  )
}
