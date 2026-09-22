import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { Loader2, MapPin, Star } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { JobTypeBadge, PriorityBadge } from "./components/JobBadges"
import { PhotoCapture } from "./components/PhotoCapture"
import { useJobDetail, useMyTechnician, useQueueGoogleReviewLog } from "@/hooks/useTechnician"
import { formatCurrency } from "@/lib/sale-calc"
import { minutesBetween } from "@/lib/visit-duration"

type ReviewMember = { id: string; name: string; is_primary: boolean; google_review_stars: number | null; google_review_photo_url: string | null }

/**
 * Technician KPI section (2026-09-22): logs a Google review claim against
 * THIS closed visit — member, ticket and technician are all already known
 * from context, so attribution is fully automatic (no dropdown of jobs, no
 * manual technician selection). Photo is mandatory: the submit button stays
 * disabled until one is captured, matching canAdvanceFrom's gating pattern in
 * OnSiteVisitPage, and the claim doesn't count toward any KPI until the
 * server-side RPC confirms it (see log_technician_google_review).
 */
function GoogleReviewLogCard({ orgId, visitId, members }: { orgId: string; visitId: string; members: ReviewMember[] }) {
  const { t } = useTranslation()
  const [memberId, setMemberId] = useState<string | null>(members.find((m) => m.is_primary)?.id ?? members[0]?.id ?? null)
  const [stars, setStars] = useState(0)
  const [photo, setPhoto] = useState<string | null>(null)
  const [submitted, setSubmitted] = useState(false)
  const queueReview = useQueueGoogleReviewLog()

  if (members.length === 0) return null

  const selectedMember = members.find((m) => m.id === memberId)
  const canSubmit = !!memberId && stars > 0 && !!photo

  async function onSubmit() {
    if (!memberId || !photo) return
    await queueReview.mutateAsync({ orgId, visitId, memberId, stars, photoUrl: photo })
    setSubmitted(true)
  }

  return (
    <Card className="gap-3">
      <p className="px-1 text-sm font-semibold text-text">{t("technician.history.googleReview.title")}</p>

      {submitted ? (
        <p className="px-1 text-sm font-medium text-success">{t("technician.history.googleReview.submitted")}</p>
      ) : (
        <>
          {members.length > 1 ? (
            <select
              aria-label={t("technician.history.googleReview.selectMember")}
              value={memberId ?? ""}
              onChange={(e) => {
                setMemberId(e.target.value)
                setStars(0)
                setPhoto(null)
              }}
              className="h-9 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              {members.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name}
                </option>
              ))}
            </select>
          ) : null}

          {selectedMember?.google_review_photo_url ? (
            <p className="px-1 text-xs text-text-muted">
              {t("technician.history.googleReview.alreadyLogged", { stars: selectedMember.google_review_stars })}
            </p>
          ) : null}

          <div className="flex items-center gap-1 px-1">
            {Array.from({ length: 5 }, (_, i) => (
              <button key={i} type="button" onClick={() => setStars(i + 1)} aria-label={t("customers.detail.rateStars", { count: i + 1 })}>
                <Star className={`size-5 ${i < stars ? "fill-warning text-warning" : "text-border"}`} />
              </button>
            ))}
          </div>

          <PhotoCapture label={t("technician.history.googleReview.photoLabel")} dataUrl={photo} onCaptured={setPhoto} />

          {queueReview.isError ? <p className="px-1 text-xs text-danger">{(queueReview.error as Error).message}</p> : null}

          <Button type="button" size="sm" disabled={!canSubmit || queueReview.isPending} onClick={onSubmit}>
            {queueReview.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("technician.history.googleReview.submit")}
          </Button>
        </>
      )}
    </Card>
  )
}

/** TECH-09 "each opens read-only TECH-06/07 summary" — reuses job detail data plus the closed visit's numbers, no editable controls. */
export function HistoryDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { visitId } = useParams<{ visitId: string }>()
  const location = useLocation()
  const ticketId = (location.state as { ticketId?: string } | null)?.ticketId

  const jobDetail = useJobDetail(ticketId)
  const technician = useMyTechnician()

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

      {visit && technician.data ? (
        <GoogleReviewLogCard orgId={technician.data.org_id} visitId={visit.id} members={ticket.customers?.customer_members ?? []} />
      ) : null}

      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
