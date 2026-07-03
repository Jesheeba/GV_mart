import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ArrowLeft, CheckCircle2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Stepper } from "@/components/shared/Stepper"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useBookServiceTicket, useMyAddresses, useMyCustomerId, useOwnedProducts } from "@/hooks/useCustomerApp"

export function BookServicePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: addresses, isLoading: loadingAddresses, isError: errorAddresses, refetch: refetchAddresses } = useMyAddresses(customerId)
  const { data: products, isLoading: loadingProducts } = useOwnedProducts(orgId)

  const [step, setStep] = useState(0)
  const [productId, setProductId] = useState<string>("")
  const [productUnknown, setProductUnknown] = useState(false)
  const [nameOfComplaint, setNameOfComplaint] = useState("")
  const [natureOfComplaint, setNatureOfComplaint] = useState("")
  const [addressId, setAddressId] = useState("")
  const [appointmentMode, setAppointmentMode] = useState<"always" | "datetime">("always")
  const [scheduledAt, setScheduledAt] = useState("")

  const bookTicket = useBookServiceTicket()

  const selectedProduct = useMemo(() => (products ?? []).find((p) => p.id === productId), [products, productId])

  const steps = [
    { key: "product", label: t("customerApp.bookService.stepProduct") },
    { key: "issue", label: t("customerApp.bookService.stepIssue") },
    { key: "address", label: t("customerApp.bookService.stepAddress") },
    { key: "confirm", label: t("customerApp.bookService.stepConfirm") },
  ]

  const isLoading = loadingId || loadingAddresses || loadingProducts
  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (errorAddresses) {
    return <FullPageError message={t("customerApp.bookService.loadError")} onRetry={() => refetchAddresses()} retryLabel={t("common.retry")} />
  }

  if (bookTicket.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.bookService.bookedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.bookedBody")}</p>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => navigate("/customer")}>
              {t("customerApp.bookService.backHome")}
            </Button>
            <Button onClick={() => navigate("/customer/bookings")}>{t("customerApp.bookService.viewBookings")}</Button>
          </div>
        </Card>
      </div>
    )
  }

  const canGoNext =
    (step === 0 && (productUnknown || !!productId)) ||
    (step === 1 && nameOfComplaint.trim().length >= 3) ||
    (step === 2 && (!!addressId || (addresses ?? []).length === 0)) ||
    false

  function goNext() {
    setStep((s) => Math.min(s + 1, steps.length - 1))
  }

  async function handleSubmit() {
    if (!orgId || !customerId) return
    bookTicket.mutate({
      orgId,
      addressId,
      productId: productUnknown ? null : productId || null,
      brandId: productUnknown ? null : (selectedProduct?.brand_id ?? null),
      modelId: productUnknown ? null : (selectedProduct?.model_id ?? null),
      nameOfComplaint,
      natureOfComplaint,
      priority: "normal",
      appointmentMode,
      scheduledAt: appointmentMode === "datetime" && scheduledAt ? new Date(scheduledAt).toISOString() : null,
    })
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button type="button" onClick={() => (step === 0 ? navigate(-1) : setStep((s) => s - 1))} className="flex items-center gap-1.5 text-sm font-medium text-text-muted">
        <ArrowLeft className="size-4" />
        {t("customerApp.bookService.back")}
      </button>
      <h1 className="text-xl font-bold text-text">{t("customerApp.bookService.title")}</h1>

      <Card>
        <Stepper steps={steps} currentIndex={step} />
      </Card>

      {step === 0 ? (
        <Card className="gap-3">
          <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.productPrompt")}</p>
          {(products ?? []).length === 0 ? (
            <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.noProductsKnown")}</p>
          ) : (
            <div className="space-y-2 px-1">
              {(products ?? []).map((p) => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => {
                    setProductId(p.id)
                    setProductUnknown(false)
                  }}
                  className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                    !productUnknown && productId === p.id ? "border-accent bg-accent-soft" : "border-border"
                  }`}
                >
                  <span className="font-medium text-text">{p.name}</span>{" "}
                  <span className="text-text-muted">{[p.brands?.name, p.models?.name].filter(Boolean).join(" · ")}</span>
                </button>
              ))}
            </div>
          )}
          <div className="px-1">
            <button
              type="button"
              onClick={() => {
                setProductUnknown(true)
                setProductId("")
              }}
              className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                productUnknown ? "border-accent bg-accent-soft text-accent" : "border-border text-text-muted"
              }`}
            >
              {t("customerApp.bookService.productUnknown")}
            </button>
          </div>
        </Card>
      ) : null}

      {step === 1 ? (
        <Card className="gap-3">
          <div className="space-y-1.5 px-1">
            <Label htmlFor="nameOfComplaint">{t("customerApp.bookService.nameOfComplaint")}</Label>
            <Input
              id="nameOfComplaint"
              value={nameOfComplaint}
              onChange={(e) => setNameOfComplaint(e.target.value)}
              placeholder={t("customerApp.bookService.nameOfComplaintPlaceholder")}
            />
          </div>
          <div className="space-y-1.5 px-1">
            <Label htmlFor="natureOfComplaint">{t("customerApp.bookService.natureOfComplaint")}</Label>
            <textarea
              id="natureOfComplaint"
              rows={3}
              value={natureOfComplaint}
              onChange={(e) => setNatureOfComplaint(e.target.value)}
              placeholder={t("customerApp.bookService.natureOfComplaintPlaceholder")}
              className="w-full rounded-xl border border-border bg-surface px-3.5 py-2.5 text-sm text-text outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
            />
          </div>
        </Card>
      ) : null}

      {step === 2 ? (
        <Card className="gap-3">
          {(addresses ?? []).length === 0 ? (
            <div className="space-y-2 px-1">
              <p className="text-sm text-warning">{t("customerApp.bookService.noAddresses")}</p>
              <Button size="sm" variant="outline" onClick={() => navigate("/customer/profile")}>
                {t("customerApp.bookService.addAddressCta")}
              </Button>
            </div>
          ) : (
            <div className="space-y-2 px-1">
              <Label>{t("customerApp.bookService.selectAddress")}</Label>
              {(addresses ?? []).map((a) => (
                <button
                  key={a.id}
                  type="button"
                  onClick={() => setAddressId(a.id)}
                  className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                    addressId === a.id ? "border-accent bg-accent-soft" : "border-border"
                  }`}
                >
                  <span className="text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</span>
                  {a.is_primary ? <span className="ml-1.5 text-xs text-accent">{t("customerApp.profile.primary")}</span> : null}
                </button>
              ))}
            </div>
          )}

          <div className="space-y-2 border-t border-border px-1 pt-3">
            <Label>{t("customerApp.bookService.appointmentMode")}</Label>
            <div className="flex gap-1 rounded-full bg-surface-alt p-1">
              {(["always", "datetime"] as const).map((m) => (
                <button
                  key={m}
                  type="button"
                  onClick={() => setAppointmentMode(m)}
                  className={`flex-1 rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                    appointmentMode === m ? "bg-ink text-white" : "text-text-muted"
                  }`}
                >
                  {t(`customerApp.bookService.mode.${m}`)}
                </button>
              ))}
            </div>
            {appointmentMode === "datetime" ? (
              <div className="space-y-1.5">
                <Input type="datetime-local" value={scheduledAt} onChange={(e) => setScheduledAt(e.target.value)} />
                <p className="text-xs text-text-muted">{t("customerApp.bookService.workHoursHint")}</p>
              </div>
            ) : null}
          </div>
        </Card>
      ) : null}

      {step === 3 ? (
        <Card className="gap-2.5">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.bookService.confirmTitle")}</h2>
          <div className="space-y-1.5 px-1 text-sm">
            <p>
              <span className="text-text-muted">{t("customerApp.bookService.stepProduct")}: </span>
              <span className="text-text">{productUnknown ? t("customerApp.bookService.productUnknown") : (selectedProduct?.name ?? "—")}</span>
            </p>
            <p>
              <span className="text-text-muted">{t("customerApp.bookService.nameOfComplaint")}: </span>
              <span className="text-text">{nameOfComplaint}</span>
            </p>
            <p>
              <span className="text-text-muted">{t("customerApp.bookService.stepAddress")}: </span>
              <span className="text-text">
                {(addresses ?? []).find((a) => a.id === addressId)
                  ? [
                      (addresses ?? []).find((a) => a.id === addressId)!.door_no,
                      (addresses ?? []).find((a) => a.id === addressId)!.area,
                    ]
                      .filter(Boolean)
                      .join(", ")
                  : "—"}
              </span>
            </p>
            <p>
              <span className="text-text-muted">{t("customerApp.bookService.appointmentMode")}: </span>
              <span className="text-text">
                {appointmentMode === "always"
                  ? t("customerApp.bookService.mode.always")
                  : scheduledAt
                    ? new Date(scheduledAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
                    : "—"}
              </span>
            </p>
          </div>
          {bookTicket.isError ? <p className="px-1 text-xs text-danger">{(bookTicket.error as Error).message}</p> : null}
        </Card>
      ) : null}

      <div className="flex justify-end gap-2">
        {step < steps.length - 1 ? (
          <Button type="button" onClick={goNext} disabled={!canGoNext} className="w-full">
            {t("customerApp.bookService.next")}
          </Button>
        ) : (
          <Button type="button" onClick={handleSubmit} disabled={bookTicket.isPending || !addressId} className="w-full">
            {bookTicket.isPending ? <Loader2 className="size-4 animate-spin" /> : t("customerApp.bookService.confirmBooking")}
          </Button>
        )}
      </div>
    </div>
  )
}
