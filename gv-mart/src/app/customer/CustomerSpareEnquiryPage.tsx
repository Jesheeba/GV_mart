import { useEffect, useState } from "react"
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
import { AddressPickerModal } from "@/components/shared/AddressPickerModal"
import { useMyAddresses, useMyCustomerId, useOwnedProducts, useSparesForProduct, useSubmitEnquiry } from "@/hooks/useCustomerApp"
import { enquirySchema, type EnquiryInput } from "@/lib/validation/customerApp"

export function CustomerSpareEnquiryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: products, isLoading, isError, refetch } = useOwnedProducts(orgId)
  const { data: addresses, isLoading: loadingAddresses } = useMyAddresses(customerId)
  const [productId, setProductId] = useState("")
  const [customProductName, setCustomProductName] = useState("")
  const [addressId, setAddressId] = useState("")
  const [addressPickerOpen, setAddressPickerOpen] = useState(false)
  const submitEnquiry = useSubmitEnquiry()

  // Task 6 (2026-07-30) — every spare mapped to the selected product, so the
  // customer picks from a real list instead of typing blind. "Can't find
  // your spare part?" falls back to the existing free-text description
  // field rather than a redundant second text input.
  const { data: sparesForProduct } = useSparesForProduct(productId || undefined)
  const [spareId, setSpareId] = useState("")
  const [manualSpare, setManualSpare] = useState(false)

  useEffect(() => {
    setSpareId("")
    setManualSpare(false)
  }, [productId])

  useEffect(() => {
    if (!addressId && addresses && addresses.length > 0) setAddressId(addresses[0].id)
  }, [addresses, addressId])

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<EnquiryInput>({ resolver: zodResolver(enquirySchema), mode: "onChange", defaultValues: { description: "" } })

  if (loadingId || isLoading || loadingAddresses) return <FullPageLoader label={t("common.loading")} />
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
  const selectedSpare = (sparesForProduct ?? []).find((s) => s.id === spareId)
  const spareLabel = selectedSpare ? [selectedSpare.name, selectedSpare.sku].filter(Boolean).join(" · ") : ""
  const hasMappedSpares = (sparesForProduct ?? []).length > 0

  const onSubmit = handleSubmit((values) => {
    if (!orgId) return
    const prefix = [productLabel && `[${productLabel}]`, spareLabel && `[Spare: ${spareLabel}]`].filter(Boolean).join(" ")
    const description = prefix ? `${prefix} ${values.description}` : values.description
    submitEnquiry.mutate({ orgId, kind: "spare", enquiryType: null, description, photoUrl: values.photoUrl, addressId: addressId || undefined })
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

          {productId && hasMappedSpares && !manualSpare ? (
            <div className="space-y-1">
              <Label>{t("customerApp.spareEnquiry.selectSpare")}</Label>
              <select
                value={spareId}
                onChange={(e) => setSpareId(e.target.value)}
                className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                <option value="">{t("customerApp.spareEnquiry.selectSparePlaceholder")}</option>
                {(sparesForProduct ?? []).map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                    {s.sku ? ` (${s.sku})` : ""}
                  </option>
                ))}
              </select>
              <button type="button" onClick={() => setManualSpare(true)} className="text-xs font-medium text-accent">
                {t("customerApp.spareEnquiry.cantFindSpare")}
              </button>
            </div>
          ) : productId && manualSpare ? (
            <button type="button" onClick={() => setManualSpare(false)} className="text-xs font-medium text-accent">
              {t("customerApp.spareEnquiry.backToSpareList")}
            </button>
          ) : null}

          <div className="space-y-1">
            <Label>{t("customerApp.bookService.selectAddress")}</Label>
            {(() => {
              const a = (addresses ?? []).find((row) => row.id === addressId)
              return a ? (
                <div className="rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm">
                  <span className="text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</span>
                  {a.is_primary ? <span className="ml-1.5 text-xs text-accent">{t("customerApp.profile.primary")}</span> : null}
                </div>
              ) : (
                <p className="rounded-xl border border-dashed border-border px-3.5 py-2.5 text-sm text-warning">
                  {t("customerApp.bookService.noAddresses")}
                </p>
              )
            })()}
            <Button type="button" size="sm" variant="outline" onClick={() => setAddressPickerOpen(true)}>
              {t("customerApp.addressPicker.changeAddress")}
            </Button>
          </div>

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

      <AddressPickerModal
        open={addressPickerOpen}
        onOpenChange={setAddressPickerOpen}
        orgId={orgId}
        customerId={customerId}
        selectedAddressId={addressId}
        onSelect={(a) => setAddressId(a.id)}
      />
    </div>
  )
}
