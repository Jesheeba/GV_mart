import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { CalendarCheck2, ChevronLeft } from "lucide-react"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useAmcContract, useAmcContractVisits } from "@/hooks/useAmc"
import { cn } from "@/lib/utils"

const AMC_STATUS_TONE: Record<string, StatusTone> = { active: "success", due_soon: "warning", expired: "danger" }
const TICKET_STATUS_TONE: Record<string, StatusTone> = { open: "warning", assigned: "info", in_progress: "warning", completed: "success", cancelled: "danger" }

function fmt(date: string | null | undefined) {
  return date ? new Date(date).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" }) : "—"
}

export function AmcContractDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: contract, isLoading, isError, refetch } = useAmcContract(id)
  const visits = useAmcContractVisits(id)

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !contract) {
    return <FullPageError message={t("amc.detail.notFound")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const today = new Date().toISOString().slice(0, 10)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2 text-sm">
        <button
          type="button"
          onClick={() => navigate("/admin/amc")}
          className="flex items-center gap-1 font-semibold text-text-muted hover:text-text"
        >
          <ChevronLeft className="size-4" />
          {t("amc.detail.breadcrumbList")}
        </button>
        <span className="text-[#C9C4BA]">/</span>
        <span className="font-semibold text-text">{contract.customers?.name ?? "—"}</span>
      </div>

      <Card className="gap-4 p-5.5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-[20px] font-extrabold tracking-tight text-text">{contract.customers?.name ?? "—"}</h1>
            <p className="text-sm font-medium text-text-muted">{contract.customers?.mobile ?? "—"}</p>
          </div>
          <StatusDot tone={AMC_STATUS_TONE[contract.status] ?? "neutral"} label={t(`amc.status.${contract.status}`)} />
        </div>
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
          <div>
            <div className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">{t("amc.list.product")}</div>
            <div className="text-sm font-semibold text-text">{contract.products?.name ?? "—"}</div>
          </div>
          <div>
            <div className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">{t("amc.list.tier")}</div>
            <div className="text-sm font-semibold text-text">{contract.amc_plans?.name ?? "—"}</div>
          </div>
          <div>
            <div className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">{t("amc.detail.startDate")}</div>
            <div className="text-sm font-semibold tabular-nums text-text">{fmt(contract.start_date)}</div>
          </div>
          <div>
            <div className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">{t("amc.list.expiry")}</div>
            <div className="text-sm font-semibold tabular-nums text-text">{fmt(contract.expiry_date)}</div>
          </div>
        </div>
      </Card>

      <Card className="gap-3 p-5.5">
        <div className="flex items-center justify-between">
          <h2 className="text-base font-bold tracking-tight text-text">{t("amc.detail.visitsScheduleTitle")}</h2>
          {!visits.isLoading ? (
            <span className="text-xs font-semibold text-text-muted">{t("amc.detail.visitsCount", { count: visits.data?.length ?? 0 })}</span>
          ) : null}
        </div>

        {visits.isLoading ? (
          <div className="flex flex-col gap-2.5">
            <Skeleton className="h-14 w-full rounded-[14px]" />
            <Skeleton className="h-14 w-full rounded-[14px]" />
            <Skeleton className="h-14 w-full rounded-[14px]" />
          </div>
        ) : visits.isError ? (
          <div className="flex flex-col items-center gap-3 py-8 text-center">
            <p className="text-sm text-text-muted">{t("amc.list.loadFailed")}</p>
          </div>
        ) : (visits.data ?? []).length === 0 ? (
          <div className="flex flex-col items-center gap-2 py-8 text-center">
            <CalendarCheck2 className="size-6 text-text-muted" />
            <p className="text-sm text-text-muted">{t("amc.detail.noVisits")}</p>
          </div>
        ) : (
          <div className="flex flex-col gap-2.5">
            {(visits.data ?? []).map((visit, i) => {
              const appointment = visit.appointments[0]
              const scheduledDate = appointment?.scheduled_at?.slice(0, 10) ?? null
              const isPast = !!scheduledDate && scheduledDate < today
              return (
                <div
                  key={visit.id}
                  className={cn(
                    "flex flex-wrap items-center justify-between gap-3 rounded-[14px] border border-border p-4",
                    isPast ? "bg-surface-alt" : "bg-surface"
                  )}
                >
                  <div className="min-w-0">
                    <div className="text-sm font-semibold text-text">{t("amc.detail.visitLabel", { n: i + 1, total: visits.data?.length ?? 0 })}</div>
                    <div className="text-xs font-medium text-text-muted">{visit.name_of_complaint ?? "—"}</div>
                  </div>
                  <div className="flex items-center gap-4">
                    <span className="text-sm font-semibold tabular-nums text-text">{fmt(appointment?.scheduled_at)}</span>
                    <StatusDot tone={TICKET_STATUS_TONE[visit.status] ?? "neutral"} label={t(`service.status.${visit.status}`)} />
                  </div>
                </div>
              )
            })}
          </div>
        )}
      </Card>
    </div>
  )
}
