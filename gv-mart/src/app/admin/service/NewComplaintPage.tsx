import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useFieldArray, useForm } from "react-hook-form"
import { AlertTriangle, Info, Loader2, Plus, Search, ShieldCheck, TriangleAlert, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Stepper } from "@/components/shared/Stepper"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { DraftBanner } from "@/components/shared/DraftBanner"
import { useProfile } from "@/hooks/useProfile"
import { useCustomer, useCustomerAutocomplete, useCustomerExemptionWindows } from "@/hooks/useCustomers"
import { brandsHooks, complaintTypesHooks, modelsHooks, productsHooks } from "@/hooks/useMasters"
import { useLocalDraft } from "@/hooks/useLocalDraft"
import {
  useCreateComplaintTicket,
  useCustomerAddresses,
  useDetectTicketType,
  useOwnedEquipment,
  useSlaSettings,
} from "@/hooks/useService"
import {
  complaintAppointmentStepSchema,
  complaintDetailsStepSchema,
  type ComplaintAppointmentStepInput,
  type ComplaintDetailsStepInput,
} from "@/lib/validation/service"
import { isBookableDate, isNarrowWindow, largestFreeWindow, type TimeWindow } from "@/lib/booking-window"
import { TicketTypeBadge } from "./TicketBadges"

function todayInput() {
  return new Date().toISOString().slice(0, 10)
}

const PRIORITIES = ["very_urgent", "urgent", "normal"] as const
const DRAFT_KEY = "gv_mart_draft:admin_new_complaint"

/** Restorable subset of the wizard's state — see useLocalDraft. Skipped
 * entirely (key is null) when arriving via a customer's own "New Ticket"
 * link (?customerId=…): that's a fresh, context-established flow, and
 * resurrecting an older draft for a different customer over it would be
 * actively wrong, not helpful. */
type NewComplaintDraftData = {
  step: number
  customerId: string
  customerLabel: string
  customerSearch: string
  addressId: string
  equipmentMode: "owned" | "new" | "none"
  selectedOwnedProductId: string
  newBrandId: string
  newModelId: string
  newProductId: string
  details: ComplaintDetailsStepInput
  appointment: ComplaintAppointmentStepInput
}

export function NewComplaintPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const prefilledCustomerId = searchParams.get("customerId")
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper below. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)

  // Step 1: customer
  const [customerSearch, setCustomerSearch] = useState("")
  const [customerId, setCustomerId] = useState("")
  const [customerLabel, setCustomerLabel] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)

  // Arrived here from a customer's own detail page ("New Ticket") — that
  // customer is already established by context, so skip straight past the
  // redundant "search for them again" step instead of re-asking.
  const prefilledCustomer = useCustomer(prefilledCustomerId ?? undefined)

  // Step 2: equipment
  const owned = useOwnedEquipment(orgId, customerId || undefined)
  const addresses = useCustomerAddresses(customerId || undefined)
  const [addressId, setAddressId] = useState("")
  const [equipmentMode, setEquipmentMode] = useState<"owned" | "new" | "none">("owned")
  const [selectedOwnedProductId, setSelectedOwnedProductId] = useState("")
  const [newBrandId, setNewBrandId] = useState("")
  const [newModelId, setNewModelId] = useState("")
  const [newProductId, setNewProductId] = useState("")
  const { data: brands } = brandsHooks.useList(orgId)
  const { data: models } = modelsHooks.useList(orgId)
  const { data: products } = productsHooks.useList(orgId)

  useEffect(() => {
    if (prefilledCustomer.data && !customerId) {
      setCustomerId(prefilledCustomer.data.id)
      setCustomerLabel(`${prefilledCustomer.data.name} · ${prefilledCustomer.data.mobile}`)
      setEquipmentMode("owned")
      setStep(1)
      setMaxStepReached((m) => Math.max(m, 1))
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prefilledCustomer.data])

  // `listCustomerAddresses` orders is_primary first, so [0] is always the
  // customer's primary address when one exists — default the ticket's
  // service address there instead of "None" (the previous default), since a
  // service call with no address is the exceptional case, not the norm.
  // Only fires while addressId is still empty, so it never clobbers an
  // admin's deliberate choice (including "None").
  useEffect(() => {
    if (!addressId && addresses.data && addresses.data.length > 0) {
      setAddressId(addresses.data[0].id)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addresses.data])

  const filteredModels = useMemo(() => (models ?? []).filter((m) => !newBrandId || m.brand_id === newBrandId), [models, newBrandId])
  const filteredProducts = useMemo(
    () => (products ?? []).filter((p) => (!newBrandId || p.brand_id === newBrandId) && (!newModelId || p.model_id === newModelId)),
    [products, newBrandId, newModelId]
  )

  const resolvedProductId =
    equipmentMode === "owned" ? selectedOwnedProductId : equipmentMode === "new" ? newProductId : ""
  const resolvedProduct = (owned.data ?? []).find((o) => o.productId === resolvedProductId)
  const resolvedBrandId = equipmentMode === "owned" ? (resolvedProduct?.brandId ?? "") : newBrandId
  const resolvedModelId = equipmentMode === "owned" ? (resolvedProduct?.modelId ?? "") : newModelId
  // category comes from the products master (owned-equipment rows don't carry it).
  const resolvedProductCategory = (products ?? []).find((p) => p.id === resolvedProductId)?.category

  // Step 3: complaint details
  const detailsForm = useForm<ComplaintDetailsStepInput>({
    resolver: zodResolver(complaintDetailsStepSchema),
    mode: "onChange",
    defaultValues: { nameOfComplaint: "", natureOfComplaint: "", priority: "normal" },
  })

  // Meeting spec E1: complaint-name master, filtered auto-suggest by the
  // resolved product's category. No product resolved -> no filter -> empty
  // suggestion list, field stays plain free text.
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  const nameOfComplaintValue = detailsForm.watch("nameOfComplaint")
  const filteredComplaintTypes = useMemo(() => {
    if (!resolvedProductCategory) return []
    const term = (nameOfComplaintValue ?? "").trim().toLowerCase()
    return (complaintTypes ?? []).filter(
      (ct) => ct.product_category === resolvedProductCategory && (!term || ct.label.toLowerCase().includes(term))
    )
  }, [complaintTypes, resolvedProductCategory, nameOfComplaintValue])

  // Step 4: type auto-detect
  const detected = useDetectTicketType(orgId, customerId, resolvedProductId || null)

  // Step 5: appointment
  const appointmentForm = useForm<ComplaintAppointmentStepInput>({
    resolver: zodResolver(complaintAppointmentStepSchema),
    mode: "onChange",
    defaultValues: { mode: "always", scheduledAt: "", autoAssign: true, windowMode: "any", unavailableWindows: [] },
  })
  const unavailableWindowsField = useFieldArray({ control: appointmentForm.control, name: "unavailableWindows" })
  const [newWinStart, setNewWinStart] = useState("")
  const [newWinEnd, setNewWinEnd] = useState("")

  // B4: the customer's own standing exemption windows — shown red so the
  // admin can see why a slot is off-limits without re-deriving it.
  const { data: exemptionWindows } = useCustomerExemptionWindows(customerId || undefined)
  const { data: slaSettings } = useSlaSettings(orgId)

  const createTicket = useCreateComplaintTicket()

  // Local draft persistence — see useLocalDraft's doc comment. Disabled for
  // the prefilled-customer entry point (see NewComplaintDraftData).
  const draftKey = prefilledCustomerId ? null : DRAFT_KEY
  const draftSnapshot: NewComplaintDraftData = {
    step,
    customerId,
    customerLabel,
    customerSearch,
    addressId,
    equipmentMode,
    selectedOwnedProductId,
    newBrandId,
    newModelId,
    newProductId,
    details: detailsForm.watch(),
    appointment: appointmentForm.watch(),
  }
  const { restoredDraft, wasRestored, discardDraft, clearDraft } = useLocalDraft<NewComplaintDraftData>(draftKey, draftSnapshot)
  const appliedDraftRef = useRef(false)
  useEffect(() => {
    if (appliedDraftRef.current || !restoredDraft) return
    appliedDraftRef.current = true
    if (restoredDraft.step != null) {
      setStep(restoredDraft.step)
      setMaxStepReached((m) => Math.max(m, restoredDraft.step))
    }
    if (restoredDraft.customerId) setCustomerId(restoredDraft.customerId)
    if (restoredDraft.customerLabel) setCustomerLabel(restoredDraft.customerLabel)
    if (restoredDraft.customerSearch) setCustomerSearch(restoredDraft.customerSearch)
    if (restoredDraft.addressId) setAddressId(restoredDraft.addressId)
    if (restoredDraft.equipmentMode) setEquipmentMode(restoredDraft.equipmentMode)
    if (restoredDraft.selectedOwnedProductId) setSelectedOwnedProductId(restoredDraft.selectedOwnedProductId)
    if (restoredDraft.newBrandId) setNewBrandId(restoredDraft.newBrandId)
    if (restoredDraft.newModelId) setNewModelId(restoredDraft.newModelId)
    if (restoredDraft.newProductId) setNewProductId(restoredDraft.newProductId)
    if (restoredDraft.details) detailsForm.reset(restoredDraft.details)
    if (restoredDraft.appointment) appointmentForm.reset(restoredDraft.appointment)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [restoredDraft])

  function discardComplaintDraft() {
    discardDraft()
    setStep(0)
    setMaxStepReached(0)
    setCustomerId("")
    setCustomerLabel("")
    setCustomerSearch("")
    setAddressId("")
    setEquipmentMode("owned")
    setSelectedOwnedProductId("")
    setNewBrandId("")
    setNewModelId("")
    setNewProductId("")
    detailsForm.reset({ nameOfComplaint: "", natureOfComplaint: "", priority: "normal" })
    appointmentForm.reset({ mode: "always", scheduledAt: "", autoAssign: true, windowMode: "any", unavailableWindows: [] })
  }

  const steps = [
    { key: "customer", label: t("service.newComplaint.stepCustomer") },
    { key: "equipment", label: t("service.newComplaint.stepEquipment") },
    { key: "complaint", label: t("service.newComplaint.stepComplaint") },
    { key: "type", label: t("service.newComplaint.stepType") },
    { key: "priority", label: t("service.newComplaint.stepPriority") },
    { key: "appointment", label: t("service.newComplaint.stepAppointment") },
  ]

  async function goNext() {
    if (step === 0 && !customerId) return
    if (step === 2) {
      const valid = await detailsForm.trigger(["nameOfComplaint", "natureOfComplaint"])
      if (!valid) return
    }
    if (step === 4) {
      const valid = await detailsForm.trigger(["priority"])
      if (!valid) return
    }
    const next = Math.min(step + 1, steps.length - 1)
    setStep(next)
    setMaxStepReached((m) => Math.max(m, next))
  }

  async function handleSubmit() {
    const appointmentValid = await appointmentForm.trigger()
    if (!appointmentValid) return
    const appt = appointmentForm.getValues()
    const details = detailsForm.getValues()

    const result = await createTicket.mutateAsync({
      orgId: orgId!,
      customerId,
      addressId: addressId || null,
      productId: resolvedProductId || null,
      brandId: resolvedBrandId || null,
      modelId: resolvedModelId || null,
      nameOfComplaint: details.nameOfComplaint,
      natureOfComplaint: details.natureOfComplaint || null,
      priority: details.priority,
      channel: "call",
      appointmentMode: appt.mode,
      scheduledAt: appt.mode === "datetime" && appt.scheduledAt ? new Date(`${appt.scheduledAt}T00:00:00`).toISOString() : null,
      autoAssign: appt.autoAssign,
      availableFrom: null,
      availableTo: null,
      // B1: raw marks only — exemption windows are folded in server-side.
      unavailableWindows: appt.mode === "datetime" ? (appt.windowMode === "any" ? [] : appt.unavailableWindows) : null,
    })
    clearDraft()
    navigate(`/admin/service/${result.ticket_id}`)
  }

  const canGoNext =
    (step === 0 && !!customerId) ||
    (step === 1 && (equipmentMode === "none" || !!resolvedProductId)) ||
    step === 2 ||
    step === 3 ||
    (step === 4 && !!detailsForm.watch("priority")) ||
    false

  return (
    <div className="mx-auto max-w-4xl space-y-4 pt-2">
      <h1 className="text-2xl font-bold text-text">{t("service.newComplaint.title")}</h1>

      {draftKey ? (
        <DraftBanner
          restored={wasRestored}
          autosaveNote={t("service.newComplaint.draft.autosaveNote")}
          restoredNote={t("service.newComplaint.draft.restoredNote")}
          discardLabel={t("service.newComplaint.draft.discard")}
          discardWarning={t("service.newComplaint.draft.discardWarning")}
          confirmDiscardLabel={t("service.newComplaint.draft.confirmDiscard")}
          cancelLabel={t("common.cancel")}
          onConfirmDiscard={discardComplaintDraft}
        />
      ) : null}

      <Card className="px-5">
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} onStepClick={setStep} />
      </Card>

      {step === 0 ? (
        <Card className="gap-3 px-5">
          <Label htmlFor="customer-search">{t("service.newComplaint.customerSearch")}</Label>
          <Autocomplete
            id="customer-search"
            value={customerId ? customerLabel : customerSearch}
            onChange={(v) => {
              setCustomerSearch(v)
              setCustomerId("")
            }}
            suggestions={customerAutocomplete.data ?? []}
            loading={customerAutocomplete.isFetching}
            icon={<Search className="size-4" />}
            emptyMessage={t("common.noData")}
            getKey={(c) => c.id}
            getLabel={(c) => (
              <span>
                <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
              </span>
            )}
            onSelect={(c) => {
              setCustomerId(c.id)
              setCustomerLabel(`${c.name} · ${c.mobile}`)
              setEquipmentMode("owned")
              setSelectedOwnedProductId("")
              setAddressId("")
            }}
          />
          {!customerId ? <p className="text-xs text-text-muted">{t("service.newComplaint.customerSearchHint")}</p> : null}
        </Card>
      ) : null}

      {step === 1 ? (
        <Card className="gap-3 px-5">
          <div className="space-y-1.5">
            <Label>{t("service.newComplaint.address")}</Label>
            <select
              value={addressId}
              onChange={(e) => setAddressId(e.target.value)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("service.newComplaint.addressNone")}</option>
              {(addresses.data ?? []).map((a) => (
                <option key={a.id} value={a.id}>
                  {[a.door_no, a.area].filter(Boolean).join(", ") || a.id.slice(0, 8)}
                  {a.is_primary ? ` (${t("customers.detail.primary")})` : ""}
                </option>
              ))}
            </select>
          </div>

          <div className="flex gap-1 rounded-full bg-surface-alt p-1">
            {(["owned", "new", "none"] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setEquipmentMode(m)}
                className={`flex-1 rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                  equipmentMode === m ? "bg-ink text-white" : "text-text-muted"
                }`}
              >
                {t(`service.newComplaint.equipmentMode.${m}`)}
              </button>
            ))}
          </div>

          {equipmentMode === "owned" ? (
            owned.isLoading ? (
              <p className="text-sm text-text-muted">{t("common.loading")}</p>
            ) : (owned.data ?? []).length === 0 ? (
              <p className="text-sm text-text-muted">{t("service.newComplaint.noOwnedEquipment")}</p>
            ) : (
              <div className="space-y-2">
                {(owned.data ?? []).map((o) => (
                  <button
                    key={o.productId}
                    type="button"
                    onClick={() => setSelectedOwnedProductId(o.productId)}
                    className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                      selectedOwnedProductId === o.productId ? "border-accent bg-accent-soft" : "border-border"
                    }`}
                  >
                    <span className="font-medium text-text">{o.productName}</span>{" "}
                    <span className="text-text-muted">{[o.brandName, o.modelName].filter(Boolean).join(" · ")}</span>
                  </button>
                ))}
              </div>
            )
          ) : equipmentMode === "new" ? (
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
              <div className="space-y-1.5">
                <Label>{t("service.newComplaint.brand")}</Label>
                <select
                  value={newBrandId}
                  onChange={(e) => {
                    setNewBrandId(e.target.value)
                    setNewModelId("")
                    setNewProductId("")
                  }}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="">{t("service.filters.all")}</option>
                  {(brands ?? []).map((b) => (
                    <option key={b.id} value={b.id}>
                      {b.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-1.5">
                <Label>{t("service.newComplaint.model")}</Label>
                <select
                  value={newModelId}
                  onChange={(e) => {
                    setNewModelId(e.target.value)
                    setNewProductId("")
                  }}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="">{t("service.filters.all")}</option>
                  {filteredModels.map((m) => (
                    <option key={m.id} value={m.id}>
                      {m.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-1.5">
                <Label>{t("service.newComplaint.product")}</Label>
                <select
                  value={newProductId}
                  onChange={(e) => setNewProductId(e.target.value)}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                >
                  <option value="">{t("service.filters.all")}</option>
                  {filteredProducts.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              </div>
            </div>
          ) : (
            <p className="text-sm text-text-muted">{t("service.newComplaint.equipmentNoneHint")}</p>
          )}
        </Card>
      ) : null}

      {step === 2 ? (
        <Card className="gap-3 px-5">
          <div className="space-y-1.5">
            <Label htmlFor="nameOfComplaint">{t("service.newComplaint.nameOfComplaint")}</Label>
            <Autocomplete
              id="nameOfComplaint"
              value={nameOfComplaintValue ?? ""}
              onChange={(v) => detailsForm.setValue("nameOfComplaint", v, { shouldValidate: true })}
              suggestions={filteredComplaintTypes}
              placeholder={t("service.newComplaint.nameOfComplaintPlaceholder")}
              emptyMessage={t("common.noData")}
              getKey={(ct) => ct.id}
              getLabel={(ct) => ct.label}
              onSelect={(ct) => detailsForm.setValue("nameOfComplaint", ct.label, { shouldValidate: true })}
            />
            {detailsForm.formState.errors.nameOfComplaint ? (
              <p className="text-xs text-danger">{t(detailsForm.formState.errors.nameOfComplaint.message!)}</p>
            ) : null}
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="natureOfComplaint">{t("service.newComplaint.natureOfComplaint")}</Label>
            <Input
              id="natureOfComplaint"
              placeholder={t("service.newComplaint.natureOfComplaintPlaceholder")}
              {...detailsForm.register("natureOfComplaint")}
            />
            <p className="text-xs text-text-muted">{t("service.newComplaint.natureOfComplaintHint")}</p>
          </div>
        </Card>
      ) : null}

      {step === 3 ? (
        <Card className="gap-3 px-5">
          {detected.isLoading ? (
            <p className="flex items-center gap-2 text-sm text-text-muted">
              <Loader2 className="size-4 animate-spin" /> {t("common.loading")}
            </p>
          ) : detected.data ? (
            <div className="space-y-2">
              <div className="flex items-center gap-2">
                <TicketTypeBadge type={detected.data.type} />
                {detected.data.type === "paid" ? (
                  <span className="flex items-center gap-1 text-xs text-text-muted">
                    <TriangleAlert className="size-3.5" /> {t("service.newComplaint.typeNotSelectable")}
                  </span>
                ) : (
                  <span className="flex items-center gap-1 text-xs text-success">
                    <ShieldCheck className="size-3.5" /> {t(detected.data.reason_key)}
                  </span>
                )}
              </div>
              {detected.data.type === "amc" ? (
                <p className="text-xs text-text-muted">
                  {t("service.newComplaint.amcCoverage", {
                    start: detected.data.amc_start_date,
                    expiry: detected.data.amc_expiry_date,
                  })}
                </p>
              ) : null}
              {detected.data.type === "warranty" ? (
                <p className="text-xs text-text-muted">
                  {t("service.newComplaint.warrantyCoverage", {
                    start: detected.data.warranty_start_date,
                    expiry: detected.data.warranty_expiry_date,
                  })}
                </p>
              ) : null}
              {detected.data.type === "paid" ? <p className="text-xs text-text-muted">{t("service.newComplaint.paidHint")}</p> : null}
            </div>
          ) : null}
        </Card>
      ) : null}

      {step === 4 ? (
        <Card className="gap-3 px-5">
          <Label>{t("service.newComplaint.priority")}</Label>
          <div className="flex gap-2">
            {PRIORITIES.map((p) => (
              <button
                key={p}
                type="button"
                onClick={() => detailsForm.setValue("priority", p, { shouldValidate: true })}
                className={`flex-1 rounded-xl border px-3.5 py-2.5 text-sm font-medium transition-colors ${
                  detailsForm.watch("priority") === p ? "border-accent bg-accent-soft text-accent" : "border-border text-text-muted"
                }`}
              >
                {t(`service.priority.${p}`)}
              </button>
            ))}
          </div>
        </Card>
      ) : null}

      {step === 5 ? (
        <Card className="gap-3 px-5">
          <Label>{t("service.newComplaint.appointmentMode")}</Label>
          <div className="flex gap-1 rounded-full bg-surface-alt p-1">
            {(["always", "datetime"] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => appointmentForm.setValue("mode", m, { shouldValidate: true })}
                className={`flex-1 rounded-full px-3 py-1.5 text-sm font-medium transition-colors ${
                  appointmentForm.watch("mode") === m ? "bg-ink text-white" : "text-text-muted"
                }`}
              >
                {t(`service.appointment.${m}`)}
              </button>
            ))}
          </div>
          {appointmentForm.watch("mode") === "datetime" ? (
            (() => {
              const workStart = (slaSettings?.work_start ?? "09:00").slice(0, 5)
              const workEnd = (slaSettings?.work_end ?? "19:30").slice(0, 5)
              const narrowThreshold = slaSettings?.narrow_window_threshold_minutes ?? 90
              const estimatedMinutes = slaSettings?.default_duration_paid_minutes ?? 45
              const windowMode = appointmentForm.watch("windowMode")
              const unavailableWindows = appointmentForm.watch("unavailableWindows") ?? []
              const exemptionBlocks: TimeWindow[] = (exemptionWindows ?? []).map((w) => ({ start: w.start_time.slice(0, 5), end: w.end_time.slice(0, 5) }))
              const blockedForPreview = windowMode === "any" ? exemptionBlocks : [...unavailableWindows, ...exemptionBlocks]
              const freeWindow = largestFreeWindow(workStart, workEnd, blockedForPreview)
              const narrow = isNarrowWindow(freeWindow, narrowThreshold)
              const bookableToday = isBookableDate(freeWindow, narrowThreshold, estimatedMinutes)
              const pickedDate = appointmentForm.watch("scheduledAt")

              return (
                <div className="space-y-3">
                  <div className="space-y-1.5">
                    <Label htmlFor="scheduledAt">{t("service.newComplaint.scheduledAt")}</Label>
                    <Input
                      id="scheduledAt"
                      type="date"
                      min={todayInput()}
                      aria-invalid={!!appointmentForm.formState.errors.scheduledAt}
                      {...appointmentForm.register("scheduledAt")}
                    />
                    <p className="text-xs text-text-muted">{t("service.newComplaint.workHoursHint")}</p>
                    {appointmentForm.formState.errors.scheduledAt ? (
                      <p className="text-xs text-danger">{t(appointmentForm.formState.errors.scheduledAt.message!)}</p>
                    ) : null}
                  </div>

                  <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                    {(["any", "custom"] as const).map((wm) => (
                      <button
                        key={wm}
                        type="button"
                        onClick={() => appointmentForm.setValue("windowMode", wm, { shouldValidate: true })}
                        className={`flex-1 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                          windowMode === wm ? "bg-ink text-white" : "text-text-muted"
                        }`}
                      >
                        {t(`customerApp.bookService.windowMode.${wm}`)}
                      </button>
                    ))}
                  </div>

                  {windowMode === "any" ? (
                    <div className="flex items-start gap-2 rounded-xl border border-accent/30 bg-accent-soft px-3.5 py-2.5 text-xs text-text">
                      <Info className="mt-0.5 size-3.5 shrink-0 text-accent" />
                      <span>{t("customerApp.bookService.anyTimeInfo", { start: workStart, end: workEnd })}</span>
                    </div>
                  ) : (
                    <div className="space-y-2.5">
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
                        <p className="text-xs font-medium text-text-muted">{t("customerApp.bookService.unavailableWindowsLabel")}</p>
                        {unavailableWindowsField.fields.length === 0 ? (
                          <p className="text-xs text-text-muted">{t("customerApp.bookService.noUnavailableWindows")}</p>
                        ) : (
                          <div className="flex flex-wrap gap-1.5">
                            {unavailableWindowsField.fields.map((f, i) => (
                              <span key={f.id} className="flex items-center gap-1 rounded-full border border-danger/30 bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
                                {f.start}–{f.end}
                                <button type="button" onClick={() => unavailableWindowsField.remove(i)} aria-label={t("common.remove")}>
                                  <X className="size-3" />
                                </button>
                              </span>
                            ))}
                          </div>
                        )}
                      </div>

                      <div className="flex items-end gap-2">
                        <div className="flex-1 space-y-1.5">
                          <Label htmlFor="newWinStart">{t("service.newComplaint.availableFrom")}</Label>
                          <Input id="newWinStart" type="time" value={newWinStart} onChange={(e) => setNewWinStart(e.target.value)} />
                        </div>
                        <div className="flex-1 space-y-1.5">
                          <Label htmlFor="newWinEnd">{t("service.newComplaint.availableTo")}</Label>
                          <Input id="newWinEnd" type="time" value={newWinEnd} onChange={(e) => setNewWinEnd(e.target.value)} />
                        </div>
                        <Button
                          type="button"
                          size="icon"
                          variant="outline"
                          disabled={!newWinStart || !newWinEnd || newWinStart >= newWinEnd}
                          onClick={() => {
                            unavailableWindowsField.append({ start: newWinStart, end: newWinEnd })
                            setNewWinStart("")
                            setNewWinEnd("")
                          }}
                        >
                          <Plus className="size-4" />
                        </Button>
                      </div>
                    </div>
                  )}

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
              )
            })()
          ) : null}
          <label className="flex items-center gap-2 text-sm text-text">
            <input type="checkbox" {...appointmentForm.register("autoAssign")} className="size-4 rounded border-border" />
            {t("service.newComplaint.autoAssign")}
          </label>

          {createTicket.error ? (
            <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{(createTicket.error as Error).message}</p>
          ) : null}
        </Card>
      ) : null}

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => (step === 0 ? navigate(-1) : setStep((s) => s - 1))}>
          {step === 0 ? t("common.cancel") : t("customers.form.back")}
        </Button>
        {step < steps.length - 1 ? (
          <Button type="button" onClick={goNext} disabled={!canGoNext}>
            {t("customers.form.next")}
          </Button>
        ) : (
          <Button type="button" onClick={handleSubmit} disabled={createTicket.isPending}>
            {createTicket.isPending ? <Loader2 className="size-4 animate-spin" /> : t("service.newComplaint.create")}
          </Button>
        )}
      </div>
    </div>
  )
}
