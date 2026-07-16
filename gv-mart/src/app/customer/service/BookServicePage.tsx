import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { ArrowLeft, CheckCircle2, ChevronRight, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Stepper } from "@/components/shared/Stepper"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { DraftBanner } from "@/components/shared/DraftBanner"
import {
  useBookServiceTicket,
  useCustomerAppSettings,
  useMyAddresses,
  useMyCustomerId,
  useMyOwnedProducts,
  useOwnedProducts,
} from "@/hooks/useCustomerApp"
import { useLocalDraft } from "@/hooks/useLocalDraft"

const DRAFT_KEY = "gv_mart_draft:customer_book_service"
const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const
type ProductView = "owned" | "categories" | "category"

/** Restorable subset of the wizard's state — see useLocalDraft. */
type BookServiceDraftData = {
  step: number
  productId: string
  productUnknown: boolean
  nameOfComplaint: string
  natureOfComplaint: string
  addressId: string
  appointmentMode: "always" | "datetime"
  scheduledAt: string
}

export function BookServicePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: addresses, isLoading: loadingAddresses, isError: errorAddresses, refetch: refetchAddresses } = useMyAddresses(customerId)
  // "products" = full catalog (used for lookup + the "choose another product" browser).
  const { data: products, isLoading: loadingProducts } = useOwnedProducts(orgId)
  // The customer's actually-owned products (warranty/AMC on file) — the default, primary picker path.
  const { data: myProducts, isLoading: loadingMyProducts } = useMyOwnedProducts(customerId)
  const { data: settings } = useCustomerAppSettings(orgId)

  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper above. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)
  const [productId, setProductId] = useState<string>("")
  const [productUnknown, setProductUnknown] = useState(false)
  const [productView, setProductView] = useState<ProductView>("owned")
  const [selectedCategory, setSelectedCategory] = useState<string>("")
  const [nameOfComplaint, setNameOfComplaint] = useState("")
  const [natureOfComplaint, setNatureOfComplaint] = useState("")
  const [addressId, setAddressId] = useState("")
  const [appointmentMode, setAppointmentMode] = useState<"always" | "datetime">("always")
  const [scheduledAt, setScheduledAt] = useState("")

  const bookTicket = useBookServiceTicket()

  const selectedProduct = useMemo(() => (products ?? []).find((p) => p.id === productId), [products, productId])

  // Local draft persistence — see useLocalDraft's doc comment.
  const draftSnapshot: BookServiceDraftData = {
    step,
    productId,
    productUnknown,
    nameOfComplaint,
    natureOfComplaint,
    addressId,
    appointmentMode,
    scheduledAt,
  }
  const { restoredDraft, wasRestored, discardDraft, clearDraft } = useLocalDraft<BookServiceDraftData>(DRAFT_KEY, draftSnapshot)
  const appliedDraftRef = useRef(false)
  useEffect(() => {
    if (appliedDraftRef.current || !restoredDraft) return
    appliedDraftRef.current = true
    if (restoredDraft.step != null) {
      setStep(restoredDraft.step)
      setMaxStepReached((m) => Math.max(m, restoredDraft.step))
    }
    if (restoredDraft.productId) setProductId(restoredDraft.productId)
    if (restoredDraft.productUnknown) setProductUnknown(restoredDraft.productUnknown)
    if (restoredDraft.nameOfComplaint) setNameOfComplaint(restoredDraft.nameOfComplaint)
    if (restoredDraft.natureOfComplaint) setNatureOfComplaint(restoredDraft.natureOfComplaint)
    if (restoredDraft.addressId) setAddressId(restoredDraft.addressId)
    if (restoredDraft.appointmentMode) setAppointmentMode(restoredDraft.appointmentMode)
    if (restoredDraft.scheduledAt) setScheduledAt(restoredDraft.scheduledAt)
  }, [restoredDraft])

  // The booking is done — the local draft has served its purpose and would
  // otherwise sit around as stale dead data offering to "resume" a booking
  // that's already been submitted.
  useEffect(() => {
    if (bookTicket.isSuccess) clearDraft()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookTicket.isSuccess])

  // Default straight to the primary address — listMyAddresses already orders
  // is_primary first, so [0] is always the right one — instead of asking the
  // customer to pick again on every booking. Only fires while addressId is
  // still empty, so it never overrides a restored draft's own choice.
  // Changing address is a Profile action, not part of this flow.
  useEffect(() => {
    if (!addressId && addresses && addresses.length > 0) {
      setAddressId(addresses[0].id)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addresses])

  function discardBookingDraft() {
    discardDraft()
    setStep(0)
    setMaxStepReached(0)
    setProductId("")
    setProductUnknown(false)
    setNameOfComplaint("")
    setNatureOfComplaint("")
    setAddressId("")
    setAppointmentMode("always")
    setScheduledAt("")
  }

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

  // v2.2 §6.4 working hours (09:00–19:30) — settings.work_start/end are the
  // admin-editable source of truth; these literals are only the fallback for
  // the brief window before settings has loaded.
  const workStart = (settings?.work_start ?? "09:00").slice(0, 5)
  const workEnd = (settings?.work_end ?? "19:30").slice(0, 5)
  const scheduledTime = scheduledAt.slice(11, 16)
  const scheduledAtWithinHours = !!scheduledAt && scheduledTime >= workStart && scheduledTime <= workEnd
  // "Anytime" needs nothing further; "datetime" mode isn't valid until a
  // time is actually picked and it falls within working hours — previously
  // this wasn't checked at all, letting an empty/out-of-hours pick through.
  const appointmentValid = appointmentMode === "always" || scheduledAtWithinHours

  const canGoNext =
    (step === 0 && (productUnknown || !!productId)) ||
    (step === 1 && nameOfComplaint.trim().length >= 3) ||
    (step === 2 && !!addressId && appointmentValid) ||
    false

  function goNext() {
    const next = Math.min(step + 1, steps.length - 1)
    setStep(next)
    setMaxStepReached((m) => Math.max(m, next))
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

      <DraftBanner
        restored={wasRestored}
        autosaveNote={t("customerApp.bookService.draft.autosaveNote")}
        restoredNote={t("customerApp.bookService.draft.restoredNote")}
        discardLabel={t("customerApp.bookService.draft.discard")}
        discardWarning={t("customerApp.bookService.draft.discardWarning")}
        confirmDiscardLabel={t("customerApp.bookService.draft.confirmDiscard")}
        cancelLabel={t("common.cancel")}
        onConfirmDiscard={discardBookingDraft}
      />

      <Card>
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} onStepClick={setStep} />
      </Card>

      {step === 0 ? (
        <Card className="gap-3">
          {productView === "owned" ? (
            <>
              <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.myProductsPrompt")}</p>
              {loadingMyProducts ? (
                <Skeleton className="h-24 w-full" />
              ) : (myProducts ?? []).length === 0 ? (
                <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.noOwnedProducts")}</p>
              ) : (
                <div className="space-y-2 px-1">
                  {(myProducts ?? []).map((p) => (
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
                  onClick={() => setProductView("categories")}
                  className="block w-full rounded-xl border border-border px-3.5 py-2.5 text-left text-sm text-accent"
                >
                  {t("customerApp.bookService.chooseAnotherProduct")}
                </button>
              </div>
            </>
          ) : productView === "categories" ? (
            <>
              <button type="button" onClick={() => setProductView("owned")} className="flex items-center gap-1.5 px-1 text-xs font-medium text-text-muted">
                <ArrowLeft className="size-3.5" />
                {t("common.back")}
              </button>
              <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.chooseCategoryPrompt")}</p>
              <div className="space-y-2 px-1">
                {CATEGORIES.map((cat) => (
                  <button
                    key={cat}
                    type="button"
                    onClick={() => {
                      setSelectedCategory(cat)
                      setProductView("category")
                    }}
                    className="flex w-full items-center justify-between rounded-xl border border-border px-3.5 py-2.5 text-left text-sm"
                  >
                    <span className="font-medium text-text">{t(`customerApp.bookService.category.${cat}`)}</span>
                    <ChevronRight className="size-4 text-text-muted" />
                  </button>
                ))}
              </div>
            </>
          ) : (
            <>
              <button type="button" onClick={() => setProductView("categories")} className="flex items-center gap-1.5 px-1 text-xs font-medium text-text-muted">
                <ArrowLeft className="size-3.5" />
                {t("common.back")}
              </button>
              <p className="px-1 text-sm font-semibold text-text">{t(`customerApp.bookService.category.${selectedCategory}`)}</p>
              {loadingProducts ? (
                <Skeleton className="h-24 w-full" />
              ) : (
                (() => {
                  const categoryProducts = (products ?? []).filter((p) => p.category === selectedCategory)
                  return categoryProducts.length === 0 ? (
                    <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.noProductsInCategory")}</p>
                  ) : (
                    <div className="space-y-2 px-1">
                      {categoryProducts.map((p) => (
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
                  )
                })()
              )}
            </>
          )}
          <div className="border-t border-border px-1 pt-3">
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
            <div className="space-y-1.5 px-1">
              <Label>{t("customerApp.bookService.selectAddress")}</Label>
              {(() => {
                const a = (addresses ?? []).find((row) => row.id === addressId) ?? addresses![0]
                return (
                  <div className="rounded-xl border border-border bg-surface-alt px-3.5 py-2.5 text-sm">
                    <span className="text-text">{[a.door_no, a.flat_no, a.street_cross, a.area, a.pincode].filter(Boolean).join(", ")}</span>
                    {a.is_primary ? <span className="ml-1.5 text-xs text-accent">{t("customerApp.profile.primary")}</span> : null}
                  </div>
                )
              })()}
              <button type="button" onClick={() => navigate("/customer/profile")} className="text-xs font-medium text-accent">
                {t("customerApp.bookService.changeAddressInProfile")}
              </button>
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
                <Input type="datetime-local" value={scheduledAt} onChange={(e) => setScheduledAt(e.target.value)} aria-invalid={!appointmentValid} />
                <p className="text-xs text-text-muted">{t("customerApp.bookService.workHoursHint")}</p>
                {!scheduledAt ? (
                  <p className="text-xs text-warning">{t("customerApp.bookService.timeRequired")}</p>
                ) : !scheduledAtWithinHours ? (
                  <p className="text-xs text-danger">{t("customerApp.bookService.timeOutsideWorkHours", { start: workStart, end: workEnd })}</p>
                ) : null}
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
          <Button type="button" onClick={handleSubmit} disabled={bookTicket.isPending || !addressId || !appointmentValid} className="w-full">
            {bookTicket.isPending ? <Loader2 className="size-4 animate-spin" /> : t("customerApp.bookService.confirmBooking")}
          </Button>
        )}
      </div>
    </div>
  )
}
