import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useLocation, useNavigate } from "react-router-dom"
import { CheckCircle2, Loader2, Star } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useSubmitRating, useTechnicianSettings } from "@/hooks/useTechnician"
import { ratingSchema, showsGoogleReviewLink } from "@/lib/validation/technician"

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

export function RatingPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const location = useLocation()
  const visitId = (location.state as { visitId?: string } | null)?.visitId

  const { data: profile } = useProfile()
  const settings = useTechnicianSettings(profile?.org_id)
  const submitRating = useSubmitRating()

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
  // No Google Business review URL exists anywhere in settings/env yet — always
  // render the button, disabled, with an explanatory note (BuildSpec's
  // explicit fallback for "no real Google Business URL exists").
  const reviewUrl: string | null = null

  async function handleSubmit() {
    if (!parsed.success || !profile) return
    await submitRating.mutateAsync({
      orgId: profile.org_id,
      visitId: visitId!,
      stars,
      review: review.trim() || undefined,
      lowRatingReason: lowRatingReason.trim() || undefined,
    })
    setSubmitted(true)
  }

  if (submitted) {
    return (
      <div className="pt-2">
        <Card className="items-center gap-3 py-8 text-center">
          <CheckCircle2 className="size-10 text-success" />
          <p className="text-base font-semibold text-text">{t("technician.rating.thankYouTitle")}</p>
          {showReviewLink ? (
            reviewUrl ? (
              <a href={reviewUrl} target="_blank" rel="noreferrer" className="w-full">
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
      <h1 className="text-xl font-bold text-text">{t("technician.rating.title")}</h1>
      <p className="px-1 text-sm text-text-muted">{t("technician.rating.subtitle")}</p>

      <Card className="items-center gap-4 py-6">
        <div className="flex gap-2">
          {[1, 2, 3, 4, 5].map((n) => (
            <button key={n} type="button" onClick={() => setStars(n)} aria-label={t("technician.rating.starAria", { n })}>
              <Star className={`size-9 ${n <= stars ? "fill-warning text-warning" : "text-border"}`} />
            </button>
          ))}
        </div>
        <p className="text-sm text-text-muted">{stars > 0 ? t(`technician.rating.starLabel.${stars}`) : t("technician.rating.tapToRate")}</p>
      </Card>

      <Card className="gap-2">
        <p className="px-1 text-sm font-semibold text-text">{t("technician.rating.reviewLabel")}</p>
        <textarea value={review} onChange={(e) => setReview(e.target.value)} placeholder={t("technician.rating.reviewPlaceholder")} rows={3} className={textareaClass} />
      </Card>

      {stars > 0 && stars < 3 ? (
        <Card className="gap-2">
          <p className="px-1 text-sm font-semibold text-text">{t("technician.rating.lowRatingReasonLabel")}</p>
          <textarea value={lowRatingReason} onChange={(e) => setLowRatingReason(e.target.value)} placeholder={t("technician.rating.lowRatingReasonPlaceholder")} rows={3} className={textareaClass} />
          <p className="px-1 text-xs text-text-muted">{t("technician.rating.lowRatingNotice")}</p>
        </Card>
      ) : null}

      <Button type="button" disabled={!parsed.success || submitRating.isPending} onClick={handleSubmit}>
        {submitRating.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.rating.submit")}
      </Button>
    </div>
  )
}
