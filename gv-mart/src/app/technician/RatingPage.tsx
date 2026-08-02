import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useLocation, useNavigate } from "react-router-dom"
import { ArrowLeft, CheckCircle2, Loader2, Star } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useMarkGoogleReviewClicked, useSubmitRating, useTechnicianSettings } from "@/hooks/useTechnician"
import { ratingSchema, showsGoogleReviewLink } from "@/lib/validation/technician"

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

export function RatingPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const location = useLocation()
  const visitId = (location.state as { visitId?: string } | null)?.visitId

  const { data: profile } = useProfile()
  const settings = useTechnicianSettings(profile?.org_id)
  const submitRating = useSubmitRating()
  const markReviewClicked = useMarkGoogleReviewClicked()

  const [stars, setStars] = useState(0)
  const [review, setReview] = useState("")
  const [lowRatingReason, setLowRatingReason] = useState("")
  const [submitted, setSubmitted] = useState(false)

  if (settings.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (settings.isError || !settings.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => settings.refetch()} retryLabel={t("common.retry")} />
  }
  if (!visitId) {
    return (
      <div className="pt-2">
        <Card className="items-center gap-2 py-8 text-center">
          <p className="text-sm font-medium text-text">{t("technician.rating.noVisitTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.rating.noVisitBody")}</p>
          <Button type="button" variant="outline" onClick={() => navigate("/technician")}>
            {t("technician.rating.backHome")}
          </Button>
        </Card>
      </div>
    )
  }

  const minStars = settings.data.review_link_min_stars
  const parsed = ratingSchema.safeParse({ stars, review, lowRatingReason })
  const showReviewLink = showsGoogleReviewLink(stars, minStars)
  // Admin-set in Masters & Settings (settings.google_review_url) — until an
  // org configures its own listing's review link, fall back to the same
  // disabled-button-with-note state this page always had.
  const reviewUrl = settings.data.google_review_url || null

  async function handleSubmit() {
    if (!parsed.success || !profile) return
    try {
      await submitRating.mutateAsync({
        orgId: profile.org_id,
        visitId: visitId!,
        stars,
        review: review.trim() || undefined,
        lowRatingReason: lowRatingReason.trim() || undefined,
      })
      setSubmitted(true)
    } catch {
      toast.error(t("common.actionFailed"))
    }
  }

  if (submitted) {
    return (
      <div className="pt-2">
        <Card className="items-center gap-3 py-8 text-center">
          <CheckCircle2 className="size-10 text-success" />
          <p className="text-base font-semibold text-text">{t("technician.rating.thankYouTitle")}</p>
          {showReviewLink ? (
            reviewUrl ? (
              // GV.md 1.2: this click is the live signal that gates the
              // review-time allowance (ratings.google_review_clicked) — see
              // mark_google_review_clicked. Fire-and-forget/best-effort: a
              // logging failure must never block the technician from
              // actually opening the review link.
              <a
                href={reviewUrl}
                target="_blank"
                rel="noreferrer"
                className="w-full"
                onClick={() => {
                  if (profile) void markReviewClicked.mutateAsync({ orgId: profile.org_id, visitId: visitId! }).catch(() => {})
                }}
              >
                <Button type="button" className="w-full">{t("technician.rating.googleReviewButton")}</Button>
              </a>
            ) : (
              <div className="w-full space-y-1">
                <Button type="button" className="w-full" disabled>{t("technician.rating.googleReviewButton")}</Button>
                <p className="text-xs text-text-muted">{t("technician.rating.googleReviewLinkMissing")}</p>
              </div>
            )
          ) : null}
          <Button type="button" variant="outline" className="w-full" onClick={() => navigate("/technician")}>
            {t("technician.rating.backHome")}
          </Button>
        </Card>
      </div>
    )
  }

  return (
    <div className="space-y-4 pt-2">
      <div className="flex items-center gap-2">
        <Button type="button" variant="ghost" size="icon-sm" onClick={() => navigate(-1)} aria-label={t("common.back")}>
          <ArrowLeft className="size-4" />
        </Button>
        <div>
          <h1 className="text-xl font-bold text-text">{t("technician.rating.title")}</h1>
          <p className="text-sm text-text-muted">{t("technician.rating.subtitle")}</p>
        </div>
      </div>

      <Card className="items-center gap-4 py-6">
        <div className="flex gap-2">
          {[1, 2, 3, 4, 5].map((n) => (
            <button key={n} type="button" onClick={() => setStars(n)} aria-label={t("technician.rating.starAria", { count: n })}>
              <Star className={`size-9 ${n <= stars ? "fill-warning text-warning" : "text-border"}`} />
            </button>
          ))}
        </div>
        <p className="text-sm text-text-muted">{stars > 0 ? t(`technician.rating.starLabel.${stars}`) : t("technician.rating.tapToRate")}</p>
      </Card>

      <Card className="gap-2">
        <Label htmlFor="review" className="px-1 text-sm font-semibold text-text">{t("technician.rating.reviewLabel")}</Label>
        <textarea id="review" value={review} onChange={(e) => setReview(e.target.value)} placeholder={t("technician.rating.reviewPlaceholder")} rows={3} className={textareaClass} />
      </Card>

      {stars > 0 && stars < 3 ? (
        <Card className="gap-2">
          <Label htmlFor="lowRatingReason" className="px-1 text-sm font-semibold text-text">{t("technician.rating.lowRatingReasonLabel")}</Label>
          <textarea id="lowRatingReason" value={lowRatingReason} onChange={(e) => setLowRatingReason(e.target.value)} placeholder={t("technician.rating.lowRatingReasonPlaceholder")} rows={3} className={textareaClass} />
          <p className="px-1 text-xs text-text-muted">{t("technician.rating.lowRatingNotice")}</p>
        </Card>
      ) : null}

      <Button type="button" disabled={!parsed.success || submitRating.isPending} onClick={handleSubmit}>
        {submitRating.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.rating.submit")}
      </Button>
    </div>
  )
}
