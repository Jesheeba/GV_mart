import { useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { AlertTriangle, CloudOff, Loader2, RefreshCw, Check } from "lucide-react"
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

  // Icon always shown; label text collapses below `sm` — on a 360-412dp
  // phone this chip sits alongside four other header controls, and "Synced"/
  // "Offline"/etc. spelled out every time was a big share of why the row
  // didn't fit. The icon alone still distinguishes every state (including a
  // dedicated checkmark for "synced", which previously had no icon at all).
  let chip: ReactNode
  if (stuckJobs.length > 0) {
    chip = (
      <button
        type="button"
        onClick={() => setPanelOpen(true)}
        aria-label={t("technician.sync.stuck", { count: stuckJobs.length })}
        className="inline-flex items-center gap-1 rounded-full bg-danger/10 px-2 py-1 text-xs font-medium text-danger sm:px-2.5"
      >
        <AlertTriangle className="size-3" />
        <span className="hidden sm:inline">{t("technician.sync.stuck", { count: stuckJobs.length })}</span>
      </button>
    )
  } else if (!online) {
    chip = (
      <span
        role="status"
        aria-label={t("technician.sync.offline")}
        className="inline-flex items-center gap-1 rounded-full bg-danger/10 px-2 py-1 text-xs font-medium text-danger sm:px-2.5"
      >
        <CloudOff className="size-3" />
        <span className="hidden sm:inline">{t("technician.sync.offline")}</span>
      </span>
    )
  } else if (syncing || pending > 0) {
    const label = syncing ? t("technician.sync.syncing") : t("technician.sync.pending", { count: pending })
    chip = (
      <span
        role="status"
        aria-label={label}
        className={cn("inline-flex items-center gap-1 rounded-full px-2 py-1 text-xs font-medium sm:px-2.5", syncing ? "bg-info/10 text-info" : "bg-warning/10 text-warning")}
      >
        {syncing ? <Loader2 className="size-3 animate-spin" /> : <RefreshCw className="size-3" />}
        <span className="hidden sm:inline">{label}</span>
      </span>
    )
  } else {
    chip = (
      <span
        role="status"
        aria-label={t("technician.sync.synced")}
        className="inline-flex items-center gap-1 rounded-full bg-success/10 px-2 py-1 text-xs font-medium text-success sm:px-2.5"
      >
        <Check className="size-3" />
        <span className="hidden sm:inline">{t("technician.sync.synced")}</span>
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
