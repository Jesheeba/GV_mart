import { useTranslation } from "react-i18next"
import { CloudOff, Loader2, RefreshCw } from "lucide-react"
import { useOnlineStatus } from "@/hooks/useOnlineStatus"
import { useSyncStatus } from "@/hooks/useTechnician"
import { cn } from "@/lib/utils"

/** Small always-visible status chip: offline / syncing / N pending / synced (Phase 7 offline-first requirement made visible to the technician). */
export function SyncStatusChip() {
  const { t } = useTranslation()
  const online = useOnlineStatus()
  const { pending, syncing } = useSyncStatus()

  if (!online) {
    return (
      <span className="inline-flex items-center gap-1 rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
        <CloudOff className="size-3" />
        {t("technician.sync.offline")}
      </span>
    )
  }

  if (syncing || pending > 0) {
    return (
      <span className={cn("inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium", syncing ? "bg-info/10 text-info" : "bg-warning/10 text-warning")}>
        {syncing ? <Loader2 className="size-3 animate-spin" /> : <RefreshCw className="size-3" />}
        {syncing ? t("technician.sync.syncing") : t("technician.sync.pending", { count: pending })}
      </span>
    )
  }

  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-success/10 px-2.5 py-1 text-xs font-medium text-success">
      {t("technician.sync.synced")}
    </span>
  )
}
