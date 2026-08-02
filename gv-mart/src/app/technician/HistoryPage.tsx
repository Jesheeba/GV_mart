import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ChevronRight, History as HistoryIcon } from "lucide-react"
import { Card } from "@/components/ui/card"
import { DatePicker } from "@/components/ui/date-picker"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SegButton } from "@/components/shared/SegButton"
import { JobTypeBadge } from "./components/JobBadges"
import { useMyTechnician, useMyHistory } from "@/hooks/useTechnician"
import { formatCurrency } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"

const TYPE_FILTERS: (Enums<"ticket_type"> | "all")[] = ["all", "paid", "warranty", "amc", "installation"]

export function HistoryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const technician = useMyTechnician()

  const [from, setFrom] = useState("")
  const [to, setTo] = useState("")
  const [type, setType] = useState<Enums<"ticket_type"> | "all">("all")

  const history = useMyHistory(technician.data?.id, {
    from: from ? new Date(from).toISOString() : undefined,
    to: to ? new Date(to + "T23:59:59").toISOString() : undefined,
    type: type === "all" ? undefined : type,
  })

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("technician.history.title")}</h1>

      <Card className="gap-3">
        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1">
            <label className="px-1 text-xs text-text-muted">{t("technician.history.from")}</label>
            <DatePicker value={from} onChange={setFrom} aria-label={t("technician.history.from")} />
          </div>
          <div className="space-y-1">
            <label className="px-1 text-xs text-text-muted">{t("technician.history.to")}</label>
            <DatePicker value={to} onChange={setTo} aria-label={t("technician.history.to")} />
          </div>
        </div>
        <div className="flex flex-wrap gap-[3px] rounded-full border border-border bg-surface-alt p-1">
          {TYPE_FILTERS.map((tf) => (
            <SegButton key={tf} active={type === tf} onClick={() => setType(tf)}>
              {tf === "all" ? t("technician.history.allTypes") : t(`service.type.${tf}`)}
            </SegButton>
          ))}
        </div>
      </Card>

      {history.isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : history.isError ? (
        <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => history.refetch()} retryLabel={t("common.retry")} />
      ) : !history.data || history.data.length === 0 ? (
        <Card className="items-center gap-2 py-8 text-center">
          <HistoryIcon className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.history.emptyTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.history.emptyBody")}</p>
        </Card>
      ) : (
        <div className="space-y-2.5">
          {history.data.map((visit) => {
            const ticket = visit.service_tickets
            return (
              <button key={visit.id} type="button" className="block w-full text-left" onClick={() => navigate(`/technician/history/${visit.id}`, { state: { ticketId: visit.ticket_id } })}>
                <Card className="gap-2 transition-colors hover:bg-surface-alt">
                  <div className="flex items-start justify-between gap-2 px-1">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-semibold text-text">{ticket?.customers?.name ?? t("technician.home.unknownCustomer")}</p>
                      <p className="truncate text-xs text-text-muted">{ticket?.name_of_complaint ?? "—"}</p>
                    </div>
                    <ChevronRight className="size-4 shrink-0 text-text-muted" />
                  </div>
                  <div className="flex flex-wrap items-center gap-2 px-1">
                    <JobTypeBadge type={ticket?.type ?? null} />
                    <span className="text-xs text-text-muted">
                      {visit.timer_start ? new Date(visit.timer_start).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" }) : "—"}
                    </span>
                    <span className="ml-auto text-sm font-semibold text-text">{formatCurrency(visit.service_charge ?? 0)}</span>
                  </div>
                </Card>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}
