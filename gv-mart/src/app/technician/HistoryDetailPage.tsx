import { useTranslation } from "react-i18next"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { MapPin } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { JobTypeBadge, PriorityBadge } from "./components/JobBadges"
import { useJobDetail } from "@/hooks/useTechnician"
import { formatCurrency } from "@/lib/sale-calc"

function minutesBetween(start: string | null, end: string | null) {
  if (!start || !end) return null
  return Math.max(0, Math.round((new Date(end).getTime() - new Date(start).getTime()) / 60000))
}

/** TECH-09 "each opens read-only TECH-06/07 summary" — reuses job detail data plus the closed visit's numbers, no editable controls. */
export function HistoryDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { visitId } = useParams<{ visitId: string }>()
  const location = useLocation()
  const ticketId = (location.state as { ticketId?: string } | null)?.ticketId

  const jobDetail = useJobDetail(ticketId)

  if (!ticketId) {
    return (
      <div className="pt-2">
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm text-text-muted">{t("technician.history.detailUnavailable")}</p>
          <Button type="button" variant="outline" onClick={() => navigate("/technician/history")}>
            {t("common.back")}
          </Button>
        </Card>
      </div>
    )
  }

  if (jobDetail.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (jobDetail.isError || !jobDetail.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }

  const ticket = jobDetail.data
  const visit = ticket.service_visits.find((v) => v.id === visitId)

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("technician.history.detailTitle")}</h1>
        <div className="flex items-center gap-1.5">
          <JobTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
        </div>
      </div>

      <Card className="gap-2">
        <p className="px-1 text-base font-semibold text-text">{ticket.customers?.name ?? t("technician.home.unknownCustomer")}</p>
        <p className="flex items-start gap-1.5 px-1 text-sm text-text-muted">
          <MapPin className="mt-0.5 size-3.5 shrink-0" />
          <span>{[ticket.addresses?.door_no, ticket.addresses?.area].filter(Boolean).join(", ") || "—"}</span>
        </p>
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.jobDetail.productTitle")}</p>
        <div className="grid grid-cols-2 gap-y-2 px-1 text-sm">
          <span className="text-text-muted">{t("technician.jobDetail.product")}</span>
          <span className="text-text">{ticket.products?.name ?? "—"}</span>
          <span className="text-text-muted">{t("technician.jobDetail.brand")}</span>
          <span className="text-text">{ticket.brands?.name ?? "—"}</span>
        </div>
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.history.visitSummary")}</p>
        <div className="grid grid-cols-2 gap-y-2 px-1 text-sm">
          <span className="text-text-muted">{t("technician.history.duration")}</span>
          <span className="text-text">
            {visit ? t("technician.history.durationMinutes", { minutes: minutesBetween(visit.timer_start, visit.timer_end) ?? 0 }) : "—"}
          </span>
          <span className="text-text-muted">{t("technician.history.charge")}</span>
          <span className="text-text">{formatCurrency(visit?.service_charge ?? 0)}</span>
        </div>
      </Card>

      {visit?.before_image_url || visit?.after_image_url ? (
        <Card className="gap-3">
          <p className="px-1 text-sm font-semibold text-text">{t("technician.history.photosTitle")}</p>
          <div className="grid grid-cols-2 gap-2">
            {visit.before_image_url ? <img src={visit.before_image_url} alt={t("technician.onsite.beforeImage")} className="w-full rounded-xl border border-border object-cover" /> : null}
            {visit.after_image_url ? <img src={visit.after_image_url} alt={t("technician.onsite.afterImage")} className="w-full rounded-xl border border-border object-cover" /> : null}
          </div>
        </Card>
      ) : null}

      {visit?.evidence_photo_urls && visit.evidence_photo_urls.length > 0 ? (
        <Card className="gap-3">
          <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.evidence.title")}</p>
          <div className="grid grid-cols-3 gap-2">
            {visit.evidence_photo_urls.map((url, i) => (
              <img key={i} src={url} alt={`${t("technician.onsite.evidence.title")} ${i + 1}`} className="aspect-square w-full rounded-xl border border-border object-cover" />
            ))}
          </div>
        </Card>
      ) : null}

      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
