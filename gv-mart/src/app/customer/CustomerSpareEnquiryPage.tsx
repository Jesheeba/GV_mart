import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { ArrowLeft, CheckCircle2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyCustomerId, useOwnedProducts, useSubmitEnquiry } from "@/hooks/useCustomerApp"
import { enquirySchema, type EnquiryInput } from "@/lib/validation/customerApp"

export function CustomerSpareEnquiryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: products, isLoading, isError, refetch } = useOwnedProducts(orgId)
  const [productId, setProductId] = useState("")
  const [customProductName, setCustomProductName] = useState("")
  const submitEnquiry = useSubmitEnquiry()

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<EnquiryInput>({ resolver: zodResolver(enquirySchema), mode: "onChange", defaultValues: { description: "" } })

  if (loadingId || isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError) {
    return <FullPageError message={t("customerApp.spareEnquiry.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  if (submitEnquiry.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.spareEnquiry.submittedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.spareEnquiry.submittedBody")}</p>
          <Button onClick={() => navigate("/customer")}>{t("customerApp.spareEnquiry.backHome")}</Button>
        </Card>
      </div>
    )
  }

  const selectedProduct = (products ?? []).find((p) => p.id === productId)
  const productLabel = selectedProduct
    ? [selectedProduct.name, selectedProduct.brands?.name, selectedProduct.models?.name].filter(Boolean).join(" · ")
    : customProductName

  const onSubmit = handleSubmit((values) => {
    if (!orgId) return
    const description = productLabel ? `[${productLabel}] ${values.description}` : values.description
    submitEnquiry.mutate({ orgId, kind: "spare", enquiryType: null, description, photoUrl: values.photoUrl })
  })

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => navigate(-1)} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.spareEnquiry.close")}
      </button>
      <h1 className="text-xl font-bold text-text">{t("customerApp.spareEnquiry.title")}</h1>
      <p className="text-sm text-text-muted">{t("customerApp.spareEnquiry.subtitle")}</p>

      <Card className="gap-3">
        <form onSubmit={onSubmit} className="space-y-2.5 px-1">
          <div className="space-y-1">
            <Label>{t("customerApp.spareEnquiry.selectProduct")}</Label>
            <select
              value={productId}
              onChange={(e) => {
                setProductId(e.target.value)
                if (e.target.value) setCustomProductName("")
              }}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("customerApp.spareEnquiry.selectProductPlaceholder")}</option>
              {(products ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {[p.name, p.brands?.name, p.models?.name].filter(Boolean).join(" · ")}
                </option>
              ))}
            </select>
          </div>

          {!productId ? (
            <div className="space-y-1">
              <Label>{t("customerApp.spareEnquiry.orTypeProductName")}</Label>
              <Input
                value={customProductName}
                onChange={(e) => setCustomProductName(e.target.value)}
                placeholder={t("customerApp.spareEnquiry.productNamePlaceholder")}
              />
            </div>
          ) : null}

          <div className="space-y-1">
            <Label>{t("customerApp.spareEnquiry.partDescription")}</Label>
            <textarea
              rows={3}
              placeholder={t("customerApp.spareEnquiry.partDescriptionPlaceholder")}
              aria-invalid={!!errors.description}
              className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
              {...register("description")}
            />
            {errors.description ? <p className="text-xs text-danger">{t(errors.description.message!)}</p> : null}
            <p className="text-xs text-text-muted">{t("customerApp.spareEnquiry.photoHint")}</p>
          </div>

          {submitEnquiry.isError ? <p className="text-xs text-danger">{(submitEnquiry.error as Error).message}</p> : null}

          <div className="flex justify-end gap-2 pt-1">
            <Button type="button" variant="ghost" size="sm" onClick={() => navigate(-1)}>
              {t("common.cancel")}
            </Button>
            <Button type="submit" size="sm" disabled={submitEnquiry.isPending || !orgId}>
              {submitEnquiry.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.spareEnquiry.submit")}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
