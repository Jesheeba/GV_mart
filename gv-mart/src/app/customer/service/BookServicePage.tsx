import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { AlertTriangle, ArrowLeft, CheckCircle2, ChevronRight, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Stepper } from "@/components/shared/Stepper"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { DraftBanner } from "@/components/shared/DraftBanner"
import {
  useBookServiceTicket,
  useCustomerAppSettings,
  useMyAddresses,
  useMyCustomerId,
  useMyExemptionWindows,
  useMyOwnedProducts,
  useOwnedProducts,
} from "@/hooks/useCustomerApp"
import { complaintTypesHooks } from "@/hooks/useMasters"
import { useLocalDraft } from "@/hooks/useLocalDraft"
import { generateTimeSlots, isBookableDate, isNarrowWindow, largestFreeWindow, slotsToWindows, type TimeWindow } from "@/lib/booking-window"

const DRAFT_KEY = "gv_mart_draft:customer_book_service"
const CATEGORIES = ["ro", "ac", "inverter", "battery"] as const
type ProductView = "owned" | "categories" | "category"

function todayInput() {
  return new Date().toISOString().slice(0, 10)
}

/** Restorable subset of the wizard's state — see useLocalDraft. */
type BookServiceDraftData = {
  step: number
  productId: string
  productUnknown: boolean
  nameOfComplaint: string
  natureOfComplaint: string
  addressId: string
  appointmentMode: "always" | "datetime"
  // B1 (Build Order Step 4): date-only + unavailable-windows booking model —
  // replaces the old exact-time `scheduledAt` + single availableFrom/To pair.
  pickedDate: string
  // Raw per-slot picks from the tap-to-mark grid (not the merged TimeWindow[]
  // form) — restoring straight into per-slot state avoids needing `slots`
  // (which depends on settings/exemption data) available at draft-restore
  // time, which runs before this component's data-loading guards resolve.
  unavailableSlotStarts: string[]
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
  // B4: the customer's own standing exemption windows — shown red and
  // pre-excluded from the derived available window without re-marking them.
  const { data: exemptionWindows } = useMyExemptionWindows(customerId)

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
  // "Anytime" (no-date-required) booking was removed from this flow — every
  // customer booking now requires picking a date. "always" mode still exists
  // as a valid appointment_mode elsewhere (e.g. product installations), so
  // the type/backend payload shape is untouched; this screen just never
  // offers it as a choice anymore.
  const [appointmentMode, setAppointmentMode] = useState<"always" | "datetime">("datetime")
  const [pickedDate, setPickedDate] = useState("")
  // Tap-to-mark-unavailable slot picker (replaces free-text "available
  // from/to" time entry) — the set of slot START times the customer marked
  // unavailable. Merged into TimeWindow ranges via slotsToWindows below,
  // only where that's actually needed (preview + submit).
  const [unavailableSlotStarts, setUnavailableSlotStarts] = useState<Set<string>>(new Set())

  const bookTicket = useBookServiceTicket()

  const selectedProduct = useMemo(() => (products ?? []).find((p) => p.id === productId), [products, productId])

  // Meeting spec E1: complaint-name master, filtered auto-suggest by the
  // selected product's category (AC -> Not Cooling, Sound Problem…; RO ->
  // No Water, No Taste… — different lists). No product selected yet (or
  // "not sure / not listed") -> no category to filter by, so the field
  // falls back to plain free text (suggestions list is just empty).
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  const filteredComplaintTypes = useMemo(() => {
    if (!selectedProduct) return []
    const term = nameOfComplaint.trim().toLowerCase()
    return (complaintTypes ?? []).filter(
      (ct) => ct.product_category === selectedProduct.category && (!term || ct.label.toLowerCase().includes(term))
    )
  }, [complaintTypes, selectedProduct, nameOfComplaint])

  // Local draft persistence — see useLocalDraft's doc comment.
  const draftSnapshot: BookServiceDraftData = {
    step,
    productId,
    productUnknown,
    nameOfComplaint,
    natureOfComplaint,
    addressId,
    appointmentMode,
    pickedDate,
    unavailableSlotStarts: [...unavailableSlotStarts],
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
    // A draft saved before "Anytime" was removed from this flow could still
    // have appointmentMode: "always" sitting in localStorage — coerce it so
    // a restored draft never lands in a mode this screen no longer offers a
    // way to pick or change.
    if (restoredDraft.appointmentMode) setAppointmentMode(restoredDraft.appointmentMode === "always" ? "datetime" : restoredDraft.appointmentMode)
    if (restoredDraft.pickedDate) setPickedDate(restoredDraft.pickedDate)
    if (restoredDraft.unavailableSlotStarts) setUnavailableSlotStarts(new Set(restoredDraft.unavailableSlotStarts))
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
    setAppointmentMode("datetime")
    setPickedDate("")
    setUnavailableSlotStarts(new Set())
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
        <Card className="max-w-md items-center gap-3 py-8 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.bookService.bookedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">{t("customerApp.bookService.bookedBody")}</p>
          {result?.scheduled_at ? (
            <p className="px-1 text-sm font-medium text-text">
              {new Date(result.scheduled_at).toLocaleDateString(undefined, { dateStyle: "medium" })}
              {result.available_from && result.available_to ? ` · ${result.available_from.slice(0, 5)}–${result.available_to.slice(0, 5)}` : ""}
            </p>
          ) : null}
          {result?.next_day_priority ? (
            <p className="mx-1 rounded-xl bg-warning/10 px-3.5 py-2.5 text-xs text-warning">{t("customerApp.bookService.nextDayPriorityNote")}</p>
          ) : null}
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
  const narrowThreshold = settings?.narrow_window_threshold_minutes ?? 90
  // No detected ticket type yet at booking time (that's server-side, on
  // submit) — the paid-service default is a reasonable stand-in for the
  // client-only "will this likely fit today" preview; the server always
  // recomputes with the ticket's real type once it exists.
  const estimatedMinutes = settings?.default_duration_paid_minutes ?? 45

  const exemptionBlocks: TimeWindow[] = (exemptionWindows ?? []).map((w) => ({ start: w.start_time.slice(0, 5), end: w.end_time.slice(0, 5) }))
  // Tap-to-mark slot grid — exemption-blocked slots are pre-marked/disabled
  // (see generateTimeSlots), so they don't need re-marking here on top.
  const slots = generateTimeSlots(workStart, workEnd, exemptionBlocks)
  const unavailableWindows = slotsToWindows(slots, unavailableSlotStarts)
  const blockedForPreview = [...unavailableWindows, ...exemptionBlocks]
  const freeWindow = largestFreeWindow(workStart, workEnd, blockedForPreview)
  const narrow = isNarrowWindow(freeWindow, narrowThreshold)
  const bookableToday = isBookableDate(freeWindow, narrowThreshold, estimatedMinutes)

  // B1: only a DATE is required now — "Anytime" needs nothing further.
  const appointmentValid = appointmentMode === "always" || !!pickedDate

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

  function toggleSlot(slotStart: string, blocked: boolean) {
    if (blocked) return
    setUnavailableSlotStarts((prev) => {
      const next = new Set(prev)
      if (next.has(slotStart)) next.delete(slotStart)
      else next.add(slotStart)
      return next
    })
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
      scheduledAt: appointmentMode === "datetime" && pickedDate ? new Date(`${pickedDate}T00:00:00`).toISOString() : null,
      availableFrom: null,
      availableTo: null,
      // B1: the raw marks only — exemption windows are folded in server-side
      // from customer_exemption_windows, not resubmitted as one-off marks.
      // Empty array (nothing marked) is exactly "available all day."
      unavailableWindows: appointmentMode === "datetime" ? unavailableWindows : null,
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

            {appointmentMode === "datetime" ? (
              <div className="space-y-3">
                <div className="space-y-1.5">
                  <Label htmlFor="pickedDate">{t("customerApp.bookService.pickDate")}</Label>
                  <Input id="pickedDate" type="date" min={todayInput()} value={pickedDate} onChange={(e) => setPickedDate(e.target.value)} aria-invalid={!pickedDate} />
                  {!pickedDate ? <p className="text-xs text-warning">{t("customerApp.bookService.dateRequired")}</p> : null}
                </div>

                {exemptionBlocks.length > 0 ? (
                  <div className="space-y-1.5">
                    <p className="text-xs font-medium text-text-muted">{t("customerApp.bookService.exemptionWindowsLabel")}</p>
                    <div className="flex flex-wrap gap-1.5">
                      {(exemptionWindows ?? []).map((w) => (
                        <span key={w.id} className="rounded-full border border-danger/30 bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
                          {w.label} · {w.start_time.slice(0, 5)}–{w.end_time.slice(0, 5)}
                        </span>
                      ))}
                    </div>
                  </div>
                ) : null}

                <div className="space-y-1.5">
                  <div className="flex items-center justify-between">
                    <Label>{t("customerApp.bookService.slotsLabel")}</Label>
                    {unavailableSlotStarts.size > 0 ? (
                      <button type="button" onClick={() => setUnavailableSlotStarts(new Set())} className="text-xs font-medium text-accent">
                        {t("customerApp.bookService.slotsClearAll")}
                      </button>
                    ) : null}
                  </div>
                  <p className="text-xs text-text-muted">{t("customerApp.bookService.slotsHint")}</p>
                  <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
                    {slots.map((slot) => {
                      const marked = unavailableSlotStarts.has(slot.start)
                      return (
                        <button
                          key={slot.start}
                          type="button"
                          disabled={slot.blocked}
                          onClick={() => toggleSlot(slot.start, slot.blocked)}
                          aria-pressed={marked}
                          className={`rounded-xl border px-2.5 py-2 text-xs font-medium transition-colors ${
                            slot.blocked
                              ? "cursor-not-allowed border-border bg-surface-alt text-text-muted/50 line-through"
                              : marked
                                ? "border-danger/40 bg-danger/10 text-danger"
                                : "border-success/30 bg-success/10 text-success"
                          }`}
                        >
                          {slot.start}–{slot.end}
                        </button>
                      )
                    })}
                  </div>
                </div>

                {pickedDate ? (
                  freeWindow.availableFrom ? (
                    <div className={`rounded-xl px-3.5 py-2.5 text-xs ${narrow ? "bg-warning/10 text-warning" : "bg-success/10 text-success"}`}>
                      {narrow
                        ? t("customerApp.bookService.narrowWindowWarning", { start: freeWindow.availableFrom, end: freeWindow.availableTo })
                        : t("customerApp.bookService.availableWindowPreview", { start: freeWindow.availableFrom, end: freeWindow.availableTo })}
                      {!bookableToday ? <span className="mt-1 block">{t("customerApp.bookService.mayMoveNextDay")}</span> : null}
                    </div>
                  ) : (
                    <div className="flex items-start gap-2 rounded-xl bg-danger/10 px-3.5 py-2.5 text-xs text-danger">
                      <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                      <span>{t("customerApp.bookService.fullyBlockedWarning")}</span>
                    </div>
                  )
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
                  : pickedDate
                    ? `${new Date(`${pickedDate}T00:00:00`).toLocaleDateString(undefined, { dateStyle: "medium" })}${
                        freeWindow.availableFrom ? ` · ${freeWindow.availableFrom}–${freeWindow.availableTo}` : ""
                      }`
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
