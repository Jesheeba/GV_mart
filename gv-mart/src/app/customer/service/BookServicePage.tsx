import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useLocation, useNavigate } from "react-router-dom"
import { ArrowLeft, CheckCircle2, ChevronRight, ImagePlus, Loader2, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DatePicker } from "@/components/ui/date-picker"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Stepper } from "@/components/shared/Stepper"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { DraftBanner } from "@/components/shared/DraftBanner"
import { AddressPickerModal } from "@/components/shared/AddressPickerModal"
import {
  useBookServiceTicket,
  useCustomerAppSettings,
  useMyAddresses,
  useMyAmcContracts,
  useMyCustomerId,
  useMyExemptionWindows,
  useMyOwnedProducts,
  useMyWarranties,
  useOwnedProducts,
} from "@/hooks/useCustomerApp"
import { useUploadTicketPhoto } from "@/hooks/useService"
import { complaintTypesHooks } from "@/hooks/useMasters"
import { useLocalDraft } from "@/hooks/useLocalDraft"
import { getIstNow } from "@/lib/ist"
import { AvailabilityTimeline } from "@/app/customer/components/AvailabilityTimeline"
import { largestFreeWindow, isBookableDate, type TimeWindow } from "@/lib/booking-window"

const DRAFT_KEY = "gv_mart_draft:customer_book_service"
const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const
type ProductView = "owned" | "categories" | "category"

function todayInput() {
  return getIstNow().date
}

/** Restorable subset of the wizard's state — see useLocalDraft. */
type BookServiceDraftData = {
  step: number
  productId: string
  productUnknown: boolean
  nameOfComplaint: string
  natureOfComplaint: string
  addressId: string
  pickedDate: string
  // Restored 2026-08-04 — see BookServicePage's step 2.
  unavailableWindows: TimeWindow[]
}

export function BookServicePage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const location = useLocation()
  // Task 1 (2026-07-31 audit): "My Products → Book Service" passes the
  // already-selected registered product via route state — the customer
  // must never be asked to pick it again. Read once; location.state doesn't
  // change for the life of this mount.
  const incomingProductId = (location.state as { productId?: string } | null)?.productId
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: addresses, isLoading: loadingAddresses, isError: errorAddresses, refetch: refetchAddresses } = useMyAddresses(customerId)
  // "products" = full catalog (used for lookup + the "choose another product" browser).
  const { data: products, isLoading: loadingProducts } = useOwnedProducts(orgId)
  // The customer's actually-owned products (warranty/AMC on file) — the default, primary picker path.
  const { data: myProducts, isLoading: loadingMyProducts } = useMyOwnedProducts(customerId)
  // Booking-time cost disclosure (see `isCoveredVisit` below): a product with
  // an active warranty or active/due_soon AMC on file is a free visit —
  // otherwise it's chargeable, same free-vs-paid rule the technician-side
  // "costing rule" copy already encodes, just surfaced before the customer
  // commits instead of only after a technician arrives.
  const { data: myWarranties } = useMyWarranties(customerId)
  const { data: myAmcContracts } = useMyAmcContracts(customerId)
  const { data: settings } = useCustomerAppSettings(orgId)
  const { data: exemptionWindowRows } = useMyExemptionWindows(customerId)

  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper above. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)
  const [productId, setProductId] = useState<string>("")
  const [productUnknown, setProductUnknown] = useState(false)
  // Gate-assignment-on-product (2026-08-04) — optional photo(s) offered only
  // alongside "I don't know the product", to help whoever fills the product
  // in later (see ticketPhotos.ts). Capped at 3, never blocks submission.
  const [photos, setPhotos] = useState<File[]>([])
  const [productView, setProductView] = useState<ProductView>("owned")
  const [selectedCategory, setSelectedCategory] = useState<string>("")
  const [nameOfComplaint, setNameOfComplaint] = useState("")
  const [natureOfComplaint, setNatureOfComplaint] = useState("")
  const [addressId, setAddressId] = useState("")
  const [pickedDate, setPickedDate] = useState("")
  const [unavailableWindows, setUnavailableWindows] = useState<TimeWindow[]>([])
  const [addressPickerOpen, setAddressPickerOpen] = useState(false)
  // Step 2's date/slot fields start neutral — "required" styling only kicks
  // in once the customer has actually interacted with the step, not the
  // instant it mounts pristine (see the step===2 block below).
  const [addressStepTouched, setAddressStepTouched] = useState(false)

  const bookTicket = useBookServiceTicket()
  const uploadPhoto = useUploadTicketPhoto()

  const selectedProduct = useMemo(() => (products ?? []).find((p) => p.id === productId), [products, productId])
  // Memoized per `photos` reference (not on every render) — these blob URLs
  // are cheap and short-lived (the wizard is gone by the time the booking
  // succeeds), so they're not explicitly revoked.
  const photoPreviewUrls = useMemo(() => photos.map((f) => URL.createObjectURL(f)), [photos])

  // Meeting spec E1: complaint-name master, filtered auto-suggest by the
  // selected product's category (AC -> Not Cooling, Sound Problem…; RO ->
  // No Water, No Taste… — different lists), merged with any complaints
  // scoped to this specific product (product_id set). No product selected
  // yet (or "not sure / not listed") -> no category to filter by, so the
  // field falls back to plain free text (suggestions list is just empty).
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  const filteredComplaintTypes = useMemo(() => {
    if (!selectedProduct) return []
    const term = nameOfComplaint.trim().toLowerCase()
    const matches = (complaintTypes ?? []).filter(
      (ct) =>
        ((ct.product_id === null && ct.product_category === selectedProduct.category) || ct.product_id === selectedProduct.id) &&
        (!term || ct.label.toLowerCase().includes(term))
    )
    // Dedupe case-insensitive/trimmed label: a product-specific row copied
    // verbatim from its category default would otherwise show twice.
    const seenLabels = new Set<string>()
    return matches.filter((ct) => {
      const key = ct.label.trim().toLowerCase()
      if (seenLabels.has(key)) return false
      seenLabels.add(key)
      return true
    })
  }, [complaintTypes, selectedProduct, nameOfComplaint])

  // Local draft persistence — see useLocalDraft's doc comment.
  const draftSnapshot: BookServiceDraftData = {
    step,
    productId,
    productUnknown,
    nameOfComplaint,
    natureOfComplaint,
    addressId,
    pickedDate,
    unavailableWindows,
  }
  const { restoredDraft, wasRestored, discardDraft, clearDraft } = useLocalDraft<BookServiceDraftData>(DRAFT_KEY, draftSnapshot)
  const appliedDraftRef = useRef(false)
  useEffect(() => {
    // An explicit incoming product (from My Products → Book Service) is
    // fresher intent than a stale abandoned draft — never let the draft
    // clobber it.
    if (appliedDraftRef.current || !restoredDraft || incomingProductId) return
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
    if (restoredDraft.pickedDate) setPickedDate(restoredDraft.pickedDate)
    if (restoredDraft.unavailableWindows) setUnavailableWindows(restoredDraft.unavailableWindows)
  }, [restoredDraft, incomingProductId])

  // Task 1 — skip straight past product selection (step 0) when a specific
  // registered product was already chosen on the My Products page.
  const appliedIncomingProductRef = useRef(false)
  useEffect(() => {
    if (appliedIncomingProductRef.current || !incomingProductId) return
    appliedIncomingProductRef.current = true
    setProductId(incomingProductId)
    setProductUnknown(false)
    setStep(1)
    setMaxStepReached((m) => Math.max(m, 1))
  }, [incomingProductId])

  // The booking is done — the local draft has served its purpose and would
  // otherwise sit around as stale dead data offering to "resume" a booking
  // that's already been submitted.
  useEffect(() => {
    if (bookTicket.isSuccess) clearDraft()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [bookTicket.isSuccess])

  // Fire-and-forget, best-effort — same convention as useResolveStaleBookings:
  // the booking has already succeeded by this point, so a failed photo
  // upload must never surface as an error or block the confirmation screen.
  const photosUploadedRef = useRef(false)
  useEffect(() => {
    if (!bookTicket.isSuccess || !bookTicket.data?.ticket_id || !orgId || !photos.length || photosUploadedRef.current) return
    photosUploadedRef.current = true
    photos.forEach((file) => uploadPhoto.mutate({ orgId, ticketId: bookTicket.data!.ticket_id, file }))
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

  // Moves focus to the (visually hidden) heading for the new step, so
  // advancing/going back through the wizard is announced to screen-reader
  // and keyboard users instead of silently swapping the Card's content out
  // from under a stale, already-activated Next/Back button — same pattern
  // as the technician on-site flow's step heading.
  const stepHeadingRef = useRef<HTMLHeadingElement>(null)
  useEffect(() => {
    stepHeadingRef.current?.focus()
  }, [step])

  function discardBookingDraft() {
    discardDraft()
    // An incoming product (My Products → Book Service) isn't part of the
    // discardable draft — discarding a stale draft must not un-select it.
    if (incomingProductId) {
      setStep(1)
      setMaxStepReached(1)
      setProductId(incomingProductId)
    } else {
      setStep(0)
      setMaxStepReached(0)
      setProductId("")
    }
    setProductUnknown(false)
    setPhotos([])
    setNameOfComplaint("")
    setNatureOfComplaint("")
    setAddressId("")
    setPickedDate("")
    setUnavailableWindows([])
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
    const result = bookTicket.data
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center lg:px-5">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.bookService.bookedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.bookedBody")}</p>
          {result?.scheduled_at ? (
            <p className="px-1 text-sm font-medium text-text">
              {new Date(result.scheduled_at).toLocaleDateString(undefined, { dateStyle: "medium" })}
              {result?.available_from ? ` · ${result.available_from.slice(0, 5)}–${(result.available_to ?? "").slice(0, 5)}` : ""}
            </p>
          ) : null}
          {result?.next_day_priority ? <p className="px-1 text-xs text-warning">{t("customerApp.bookService.nextDayPriorityNote")}</p> : null}
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

  // Booking-time cost disclosure — free only when the selected product has
  // an active warranty or an active/due_soon AMC contract on file; "not
  // sure / not listed" and any product without live coverage are treated as
  // a normal chargeable visit (see the hooks fetched above).
  const today = todayInput()
  const hasActiveWarranty =
    !productUnknown && !!productId && (myWarranties ?? []).some((w) => w.product_id === productId && w.expiry_date >= today)
  const hasActiveAmc =
    !productUnknown && !!productId && (myAmcContracts ?? []).some((a) => a.product_id === productId && (a.status === "active" || a.status === "due_soon"))
  const isCoveredVisit = hasActiveWarranty || hasActiveAmc

  const workStart = (settings?.work_start ?? "09:00").slice(0, 5)
  const workEnd = (settings?.work_end ?? "19:30").slice(0, 5)
  const narrowThreshold = settings?.narrow_window_threshold_minutes ?? 90
  const estimatedMinutes = settings?.default_duration_paid_minutes ?? 45
  const exemptionBlocks: TimeWindow[] = (exemptionWindowRows ?? []).map((w) => ({ start: w.start_time.slice(0, 5), end: w.end_time.slice(0, 5) }))
  const freeWindow = largestFreeWindow(workStart, workEnd, [...unavailableWindows, ...exemptionBlocks])
  const bookableToday = isBookableDate(freeWindow, narrowThreshold, estimatedMinutes)
  const hasInvalidRange = unavailableWindows.some((w) => w.end <= w.start)

  const canGoNext =
    (step === 0 && (productUnknown || !!productId)) ||
    (step === 1 && nameOfComplaint.trim().length >= 3) ||
    (step === 2 && !!addressId && !!pickedDate && !hasInvalidRange) ||
    false

  function goNext() {
    const next = Math.min(step + 1, steps.length - 1)
    setStep(next)
    setMaxStepReached((m) => Math.max(m, next))
  }

  async function handleSubmit() {
    if (!orgId || !customerId || !pickedDate) return
    bookTicket.mutate({
      orgId,
      addressId,
      productId: productUnknown ? null : productId || null,
      brandId: productUnknown ? null : (selectedProduct?.brand_id ?? null),
      modelId: productUnknown ? null : (selectedProduct?.model_id ?? null),
      nameOfComplaint,
      natureOfComplaint,
      priority: "normal",
      scheduledDate: pickedDate,
      unavailableWindows,
    })
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button
        type="button"
        onClick={() => {
          // With an incoming product, step 0 (product selection) is skipped
          // entirely — treat step 1 as the first step so "back" leaves the
          // wizard instead of surfacing a picker screen there's no reason to see.
          const firstStep = incomingProductId ? 1 : 0
          if (step <= firstStep) navigate(-1)
          else setStep((s) => s - 1)
        }}
        className="flex items-center gap-1.5 text-sm font-medium text-text-muted"
      >
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

      <Card className="lg:px-5">
        <Stepper
          steps={steps}
          currentIndex={step}
          maxCompletedIndex={maxStepReached}
          onStepClick={(next) => (incomingProductId && next === 0 ? undefined : setStep(next))}
        />
      </Card>

      <h2 ref={stepHeadingRef} tabIndex={-1} aria-live="polite" className="sr-only">
        {steps[step]?.label}
      </h2>

      {step === 0 ? (
        <Card className="gap-3 lg:px-5">
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
                      aria-pressed={!productUnknown && productId === p.id}
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
                          aria-pressed={!productUnknown && productId === p.id}
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
              aria-pressed={productUnknown}
              className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                productUnknown ? "border-accent bg-accent-soft text-accent" : "border-border text-text-muted"
              }`}
            >
              {t("customerApp.bookService.productUnknown")}
            </button>
          </div>

          {productUnknown ? (
            <div className="space-y-2 px-1">
              <Label>{t("customerApp.bookService.photoAttachLabel")}</Label>
              <p className="text-xs text-text-muted">{t("customerApp.bookService.photoAttachHint")}</p>
              <div className="flex flex-wrap gap-2">
                {photos.map((_, i) => (
                  <div key={i} className="relative size-20 shrink-0">
                    <img src={photoPreviewUrls[i]} alt="" className="size-20 rounded-lg object-cover" />
                    <button
                      type="button"
                      onClick={() => setPhotos((prev) => prev.filter((_, idx) => idx !== i))}
                      aria-label={t("customerApp.bookService.photoRemove")}
                      className="absolute -right-1.5 -top-1.5 flex size-5 items-center justify-center rounded-full bg-ink text-white"
                    >
                      <X className="size-3" />
                    </button>
                  </div>
                ))}
                {photos.length < 3 ? (
                  <label className="flex size-20 shrink-0 cursor-pointer flex-col items-center justify-center gap-1 rounded-lg border border-dashed border-border text-text-muted">
                    <ImagePlus className="size-5" />
                    <span className="text-[10px] font-medium">{t("customerApp.bookService.photoAddButton")}</span>
                    <input
                      type="file"
                      accept="image/*"
                      capture="environment"
                      className="hidden"
                      onChange={(e) => {
                        const files = Array.from(e.target.files ?? [])
                        if (files.length) setPhotos((prev) => [...prev, ...files].slice(0, 3))
                        e.target.value = ""
                      }}
                    />
                  </label>
                ) : null}
              </div>
            </div>
          ) : null}
        </Card>
      ) : null}

      {step === 1 ? (
        <Card className="gap-3 overflow-visible lg:px-5">
          <div className="space-y-1.5 px-1">
            <Label htmlFor="nameOfComplaint">{t("customerApp.bookService.nameOfComplaint")}</Label>
            <Autocomplete
              id="nameOfComplaint"
              value={nameOfComplaint}
              onChange={setNameOfComplaint}
              suggestions={filteredComplaintTypes}
              placeholder={t("customerApp.bookService.nameOfComplaintPlaceholder")}
              emptyMessage={t("common.noData")}
              getKey={(ct) => ct.id}
              getLabel={(ct) => ct.label}
              onSelect={(ct) => setNameOfComplaint(ct.label)}
              openOnFocus
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
        <Card className="gap-3 lg:px-5" onClickCapture={() => setAddressStepTouched(true)}>
          <div className="space-y-1.5 px-1">
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
              {(addresses ?? []).length === 0 ? t("customerApp.bookService.addAddressCta") : t("customerApp.addressPicker.changeAddress")}
            </Button>
          </div>

          <div className="space-y-3 border-t border-border px-1 pt-3">
            <div className="space-y-1.5">
              <Label htmlFor="pickedDate">{t("customerApp.bookService.pickDate")}</Label>
              <DatePicker
                id="pickedDate"
                min={todayInput()}
                value={pickedDate}
                onChange={setPickedDate}
                aria-invalid={addressStepTouched && !pickedDate}
              />
              {addressStepTouched && !pickedDate ? <p className="text-xs text-warning">{t("customerApp.bookService.dateRequired")}</p> : null}
            </div>

            <AvailabilityTimeline
              workStart={workStart}
              workEnd={workEnd}
              windows={unavailableWindows}
              onChange={setUnavailableWindows}
              exemptionWindows={exemptionBlocks}
              narrowThresholdMinutes={narrowThreshold}
              estimatedMinutes={estimatedMinutes}
            />
          </div>
        </Card>
      ) : null}

      {step === 3 ? (
        <Card className="gap-2.5 lg:px-5">
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
                {pickedDate
                  ? `${new Date(`${pickedDate}T00:00:00`).toLocaleDateString(undefined, { dateStyle: "medium" })}${
                      freeWindow.availableFrom ? ` · ${freeWindow.availableFrom}–${freeWindow.availableTo}` : ""
                    }`
                  : "—"}
              </span>
            </p>
            {pickedDate && !bookableToday ? <p className="px-1 text-xs text-warning">{t("customerApp.bookService.unavailability.mayMoveNextDay")}</p> : null}
            <p>
              <span className="text-text-muted">{t("customerApp.bookService.visitCostLabel")}: </span>
              <span className="text-text">
                {productUnknown
                  ? t("customerApp.bookService.visitCostUnknown")
                  : isCoveredVisit
                    ? t("customerApp.bookService.visitCostCovered")
                    : t("customerApp.bookService.visitCostChargeable")}
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
          <Button type="button" onClick={handleSubmit} disabled={bookTicket.isPending || !addressId || !pickedDate || hasInvalidRange} className="w-full">
            {bookTicket.isPending ? <Loader2 className="size-4 animate-spin" /> : t("customerApp.bookService.confirmBooking")}
          </Button>
        )}
      </div>

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
