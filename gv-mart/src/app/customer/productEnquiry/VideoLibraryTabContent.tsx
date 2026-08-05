import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Check, CheckCircle2, Loader2, MessageCircleQuestion } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { VideoCard } from "./VideoCard"
import { useSubmitEnquiry, useVideoLibrary } from "@/hooks/useCustomerApp"
import { enquirySchema, type EnquiryInput } from "@/lib/validation/customerApp"
import type { Enums } from "@/types/database"

const DESCRIPTION_FIELD_ID = "product-enquiry-description"

/**
 * Product Enquiry rebuild (2026-08-04), Phase 3 — this is the ORIGINAL
 * CustomerProductEnquiryPage.tsx body (topic chips + video grid + free-text
 * quotation form), extracted verbatim so it becomes the `video_library`
 * tab-type renderer in moduleRegistry.tsx. The hardcoded TOPICS array is
 * replaced by the `topics` prop, sourced from the admin-configured tab's
 * `config.topics` (product_enquiry_tabs) instead — everything else is
 * unchanged, so this must render bit-for-bit identically to the pre-rebuild
 * page once seeded with the same 6 topics in the same order.
 */
export function VideoLibraryTabContent({ orgId, topics }: { orgId: string | undefined; topics: Enums<"enquiry_type">[] }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: videos, isLoading, isError, refetch } = useVideoLibrary(orgId)
  const [activeTopic, setActiveTopic] = useState<Enums<"enquiry_type"> | null>(null)
  const submitEnquiry = useSubmitEnquiry()

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<EnquiryInput>({ resolver: zodResolver(enquirySchema), mode: "onChange", defaultValues: { description: "" } })

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.productEnquiry.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  if (submitEnquiry.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center lg:px-5">
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

  function focusDescriptionField() {
    const field = document.getElementById(DESCRIPTION_FIELD_ID)
    field?.scrollIntoView({ behavior: "smooth", block: "center" })
    field?.focus()
  }

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
      <div className="flex flex-wrap gap-2">
        {topics.map((topic) => {
          const active = activeTopic === topic
          return (
            <button
              key={topic}
              type="button"
              onClick={() => setActiveTopic(active ? null : topic)}
              className={`flex items-center gap-1.5 rounded-full border px-3.5 py-1.5 text-sm font-medium transition-colors ${
                active ? "border-accent bg-accent text-white" : "border-border text-text-muted hover:bg-surface-alt/60"
              }`}
            >
              {active ? <Check className="size-3.5" /> : null}
              {t(`customerApp.productEnquiry.topics.${topic}`)}
            </button>
          )
        })}
      </div>

      {activeTopic ? (
        <Card className="gap-2 lg:px-5">
          <h2 className="px-1 text-sm font-semibold text-text">{t(`customerApp.productEnquiry.topics.${activeTopic}`)}</h2>
          {videosForTopic.length === 0 ? (
            <div className="flex flex-col items-center gap-2 px-1 py-4 text-center">
              <span className="flex size-10 items-center justify-center rounded-full bg-surface-alt text-text-muted">
                <MessageCircleQuestion className="size-5" />
              </span>
              <p className="text-sm text-text-muted">{t("customerApp.productEnquiry.noContentForTopic")}</p>
              <Button type="button" variant="outline" size="sm" onClick={focusDescriptionField}>
                {t("customerApp.productEnquiry.noContentForTopicCta")}
              </Button>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-2.5 px-1">
              {videosForTopic.map((v, i) => (
                <VideoCard key={v.id} url={v.url} topic={activeTopic} index={i + 1} />
              ))}
            </div>
          )}
        </Card>
      ) : null}

      <Card className="gap-3 lg:px-5">
        <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.productEnquiry.requestQuotation")}</h2>
        <form onSubmit={onSubmit} className="space-y-2.5 px-1">
          <div className="space-y-1">
            <Label htmlFor={DESCRIPTION_FIELD_ID}>{t("customerApp.productEnquiry.description")}</Label>
            <textarea
              id={DESCRIPTION_FIELD_ID}
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
            <Button type="button" variant="ghost" size="sm" onClick={() => navigate(-1)}>
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
