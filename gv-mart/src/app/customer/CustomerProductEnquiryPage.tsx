import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { ArrowLeft, CheckCircle2, Loader2, PlayCircle, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyCustomerId, useSubmitEnquiry, useVideoLibrary } from "@/hooks/useCustomerApp"
import { enquirySchema, type EnquiryInput } from "@/lib/validation/customerApp"
import type { Enums } from "@/types/database"

const TOPICS: Enums<"enquiry_type">[] = ["online", "price", "quality", "customization", "water_premium", "budget"]

export function CustomerProductEnquiryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: videos, isLoading, isError, refetch } = useVideoLibrary(orgId)
  const [activeTopic, setActiveTopic] = useState<Enums<"enquiry_type"> | null>(null)
  const submitEnquiry = useSubmitEnquiry()

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<EnquiryInput>({ resolver: zodResolver(enquirySchema), mode: "onChange", defaultValues: { description: "" } })

  if (loadingId || isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.productEnquiry.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  if (submitEnquiry.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.productEnquiry.submittedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.productEnquiry.submittedBody")}</p>
          <Button onClick={() => navigate("/customer")}>{t("customerApp.productEnquiry.backHome")}</Button>
        </Card>
      </div>
    )
  }

  const videosForTopic = (videos ?? []).filter((v) => v.topic === activeTopic)

  const onSubmit = handleSubmit((values) => {
    if (!orgId) return
    submitEnquiry.mutate({
      orgId,
      kind: "product",
      enquiryType: activeTopic,
      description: values.description,
      photoUrl: values.photoUrl,
    })
  })

  return (
    <div className="space-y-4 pb-4 pt-2">
      <div className="flex items-center justify-between">
        <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
          <ArrowLeft className="size-4" />
          {t("customerApp.productEnquiry.close")}
        </button>
      </div>
      <h1 className="text-xl font-bold text-text">{t("customerApp.productEnquiry.title")}</h1>
      <p className="text-sm text-text-muted">{t("customerApp.productEnquiry.subtitle")}</p>

      <div className="flex flex-wrap gap-2">
        {TOPICS.map((topic) => (
          <button
            key={topic}
            type="button"
            onClick={() => setActiveTopic(activeTopic === topic ? null : topic)}
            className={`rounded-full border px-3.5 py-1.5 text-sm font-medium transition-colors ${
              activeTopic === topic ? "border-accent bg-accent-soft text-accent" : "border-border text-text-muted"
            }`}
          >
            {t(`customerApp.productEnquiry.topics.${topic}`)}
          </button>
        ))}
      </div>

      {activeTopic ? (
        <Card className="gap-2">
          <h2 className="px-1 text-sm font-semibold text-text">{t(`customerApp.productEnquiry.topics.${activeTopic}`)}</h2>
          {videosForTopic.length === 0 ? (
            <p className="px-1 text-sm text-text-muted">{t("customerApp.productEnquiry.noContentForTopic")}</p>
          ) : (
            <ul className="space-y-1.5 px-1">
              {videosForTopic.map((v) => (
                <li key={v.id}>
                  <a
                    href={v.url}
                    target="_blank"
                    rel="noreferrer"
                    className="flex items-center gap-2 rounded-xl border border-border px-3.5 py-2.5 text-sm text-accent hover:bg-surface-alt/60"
                  >
                    <PlayCircle className="size-4 shrink-0" />
                    <span className="truncate">{v.url}</span>
                  </a>
                </li>
              ))}
            </ul>
          )}
        </Card>
      ) : null}

      <Card className="gap-3">
        <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.requestQuotation")}</h2>
        <form onSubmit={onSubmit} className="space-y-2.5 px-1">
          <div className="space-y-1">
            <Label>{t("customerApp.productEnquiry.description")}</Label>
            <textarea
              rows={3}
              placeholder={t("customerApp.productEnquiry.descriptionPlaceholder")}
              aria-invalid={!!errors.description}
              className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
              {...register("description")}
            />
            {errors.description ? <p className="text-xs text-danger">{t(errors.description.message!)}</p> : null}
          </div>
          {submitEnquiry.isError ? <p className="text-xs text-danger">{(submitEnquiry.error as Error).message}</p> : null}
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={() => reset()}>
              <X className="size-3.5" />
              {t("common.cancel")}
            </Button>
            <Button type="submit" size="sm" disabled={submitEnquiry.isPending || !orgId}>
              {submitEnquiry.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.productEnquiry.requestQuotation")}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
