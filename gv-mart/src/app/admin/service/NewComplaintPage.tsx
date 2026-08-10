import { useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useSearchParams } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { Controller, useForm } from "react-hook-form"
import { Loader2, Pencil, Search, ShieldCheck, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { DatePicker } from "@/components/ui/date-picker"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { Stepper } from "@/components/shared/Stepper"
import { SegButton } from "@/components/shared/SegButton"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { DraftBanner } from "@/components/shared/DraftBanner"
import { NotInInventoryProductDialog } from "@/components/shared/NotInInventoryProductDialog"
import { useProfile } from "@/hooks/useProfile"
import { useCustomer, useCustomerAutocomplete } from "@/hooks/useCustomers"
import { brandsHooks, complaintTypesHooks, modelsHooks, productsHooks } from "@/hooks/useMasters"
import { useLocalDraft } from "@/hooks/useLocalDraft"
import { useAppointmentSlots } from "@/hooks/useCustomerApp"
import { useCreateComplaintTicket, useCustomerAddresses, useDetectTicketType, useOwnedEquipment, useTechnicians } from "@/hooks/useService"
import {
  complaintAppointmentStepSchema,
  complaintDetailsStepSchema,
  type ComplaintAppointmentStepInput,
  type ComplaintDetailsStepInput,
} from "@/lib/validation/service"
import { getIstNow } from "@/lib/ist"
import { TicketTypeBadge } from "./TicketBadges"

function todayInput() {
  return getIstNow().date
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
  equipmentMode: "owned" | "new" | "notInInventory"
  selectedOwnedProductId: string
  newBrandId: string
  newModelId: string
  newProductId: string
  unlistedProductName: string
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
  const [equipmentMode, setEquipmentMode] = useState<"owned" | "new" | "notInInventory">("owned")
  const [selectedOwnedProductId, setSelectedOwnedProductId] = useState("")
  const [newBrandId, setNewBrandId] = useState("")
  const [newModelId, setNewModelId] = useState("")
  const [newProductId, setNewProductId] = useState("")
  const [unlistedProductName, setUnlistedProductName] = useState("")
  const [notInInventoryDialogOpen, setNotInInventoryDialogOpen] = useState(false)
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

  const resolvedProductId = equipmentMode === "owned" ? selectedOwnedProductId : newProductId
  const resolvedProduct = (owned.data ?? []).find((o) => o.productId === resolvedProductId)
  const resolvedBrandId = equipmentMode === "owned" ? (resolvedProduct?.brandId ?? "") : newBrandId
  const resolvedModelId = equipmentMode === "owned" ? (resolvedProduct?.modelId ?? "") : newModelId
  // category comes from the products master (owned-equipment rows don't carry it).
  const resolvedProductCategory = (products ?? []).find((p) => p.id === resolvedProductId)?.category

  // Step 3: complaint details
  // Issue-based spare suggestions (2026-08-06) — the complaint_types row
  // resolved when the admin picked a suggestion from the "Name of complaint"
  // Autocomplete, rather than free-typing. Not form-managed (react-hook-form
  // only tracks nameOfComplaint's text) since it needs to reset to null
  // whenever that text is edited away from the selected suggestion.
  const [complaintTypeId, setComplaintTypeId] = useState<string | null>(null)
  const detailsForm = useForm<ComplaintDetailsStepInput>({
    resolver: zodResolver(complaintDetailsStepSchema),
    mode: "onChange",
    defaultValues: { nameOfComplaint: "", natureOfComplaint: "", priority: "normal" },
  })

  // Meeting spec E1: complaint-name master, filtered auto-suggest by the
  // resolved product's category, merged with any complaints scoped to this
  // specific product (product_id set). No product resolved -> no filter ->
  // empty suggestion list, field stays plain free text.
  const { data: complaintTypes } = complaintTypesHooks.useList(orgId)
  const nameOfComplaintValue = detailsForm.watch("nameOfComplaint")
  const filteredComplaintTypes = useMemo(() => {
    if (!resolvedProductId && !resolvedProductCategory) return []
    const term = (nameOfComplaintValue ?? "").trim().toLowerCase()
    const matches = (complaintTypes ?? []).filter(
      (ct) =>
        ((ct.product_id === null && ct.product_category === resolvedProductCategory) || ct.product_id === resolvedProductId) &&
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
  }, [complaintTypes, resolvedProductId, resolvedProductCategory, nameOfComplaintValue])

  // Step 4: type auto-detect
  const detected = useDetectTicketType(orgId, customerId, resolvedProductId || null)

  // Step 5: appointment — same admin-configured appointment-slot format as
  // the customer app's own booking flow (BookServicePage.tsx), instead of
  // the old free-text available-time-window builder.
  const appointmentForm = useForm<ComplaintAppointmentStepInput>({
    resolver: zodResolver(complaintAppointmentStepSchema),
    mode: "onChange",
    defaultValues: { scheduledDate: "", slotId: "", autoAssign: true },
  })
  const { data: appointmentSlots, isLoading: loadingSlots } = useAppointmentSlots(orgId)
  const activeSlots = appointmentSlots ?? []
  // If today is picked, drop slots whose window has already fully passed —
  // otherwise e.g. "Morning 08:00-12:00" is still offered/selectable at
  // 6pm. The RPC re-checks this too (defense in depth).
  const bookableSlots =
    appointmentForm.watch("scheduledDate") === todayInput()
      ? activeSlots.filter((s) => s.end_time.slice(0, 5) > getIstNow().time)
      : activeSlots

  const createTicket = useCreateComplaintTicket()
  const { data: technicians } = useTechnicians(orgId)
  const [referredByTechnicianId, setReferredByTechnicianId] = useState("")

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
    unlistedProductName,
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
    if (restoredDraft.unlistedProductName) setUnlistedProductName(restoredDraft.unlistedProductName)
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
    setUnlistedProductName("")
    detailsForm.reset({ nameOfComplaint: "", natureOfComplaint: "", priority: "normal" })
    appointmentForm.reset({ scheduledDate: "", slotId: "", autoAssign: true })
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
      productId: equipmentMode === "notInInventory" ? null : resolvedProductId || null,
      brandId: equipmentMode === "notInInventory" ? null : resolvedBrandId || null,
      modelId: equipmentMode === "notInInventory" ? null : resolvedModelId || null,
      unlistedProductName: equipmentMode === "notInInventory" ? unlistedProductName || null : null,
      nameOfComplaint: details.nameOfComplaint,
      natureOfComplaint: details.natureOfComplaint || null,
      complaintTypeId,
      priority: details.priority,
      channel: "call",
      // "always"/anytime mode was dropped from this form — every admin-
      // created ticket now gets a real date + slot, same as the customer app.
      appointmentMode: "datetime",
      autoAssign: appt.autoAssign,
      // Same plain date-string + slot-id pair as BookServicePage.tsx's own
      // p_scheduled_date/p_slot_id — the RPC's p_scheduled_date is a `date`,
      // not a timestamp, so no UTC-midnight anchoring is needed here.
      scheduledDate: appt.scheduledDate || null,
      slotId: appt.slotId || null,
      referredByTechnicianId: referredByTechnicianId || null,
    })
    clearDraft()
    navigate(`/admin/service/${result.ticket_id}`)
  }

  const canGoNext =
    (step === 0 && !!customerId) ||
    (step === 1 && (!!resolvedProductId || (equipmentMode === "notInInventory" && !!unlistedProductName.trim()))) ||
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
            {(["owned", "new", "notInInventory"] as const).map((m) => (
              <SegButton
                key={m}
                active={equipmentMode === m}
                onClick={() => (m === "notInInventory" ? setNotInInventoryDialogOpen(true) : setEquipmentMode(m))}
                className="flex-1 py-1.5 text-sm font-medium"
              >
                {t(`service.newComplaint.equipmentMode.${m}`)}
              </SegButton>
            ))}
          </div>

          {equipmentMode === "notInInventory" ? (
            <div className="flex items-center justify-between rounded-xl border border-border px-3.5 py-2.5">
              <span className="text-sm text-text">{unlistedProductName}</span>
              <Button type="button" size="icon-xs" variant="ghost" onClick={() => setNotInInventoryDialogOpen(true)}>
                <Pencil className="size-3.5" />
              </Button>
            </div>
          ) : equipmentMode === "owned" ? (
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
          ) : (
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
          )}
        </Card>
      ) : null}

      <NotInInventoryProductDialog
        open={notInInventoryDialogOpen}
        initialValue={unlistedProductName}
        onOpenChange={setNotInInventoryDialogOpen}
        onSave={(name) => {
          setUnlistedProductName(name)
          setEquipmentMode("notInInventory")
          setNotInInventoryDialogOpen(false)
        }}
      />

      {step === 2 ? (
        <Card className="gap-3 overflow-visible px-5">
          <div className="space-y-1.5">
            <Label htmlFor="nameOfComplaint">{t("service.newComplaint.nameOfComplaint")}</Label>
            <Autocomplete
              id="nameOfComplaint"
              value={nameOfComplaintValue ?? ""}
              onChange={(v) => {
                detailsForm.setValue("nameOfComplaint", v, { shouldValidate: true })
                setComplaintTypeId(null)
              }}
              suggestions={filteredComplaintTypes}
              placeholder={t("service.newComplaint.nameOfComplaintPlaceholder")}
              emptyMessage={t("common.noData")}
              getKey={(ct) => ct.id}
              getLabel={(ct) => ct.label}
              onSelect={(ct) => {
                detailsForm.setValue("nameOfComplaint", ct.label, { shouldValidate: true })
                setComplaintTypeId(ct.id)
              }}
              openOnFocus
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
          <div className="space-y-3">
            <div className="space-y-1.5">
              <Label htmlFor="scheduledDate">{t("service.newComplaint.scheduledAt")}</Label>
              <Controller
                control={appointmentForm.control}
                name="scheduledDate"
                render={({ field }) => (
                  <DatePicker
                    id="scheduledDate"
                    min={todayInput()}
                    value={field.value ?? ""}
                    onChange={field.onChange}
                    aria-invalid={!!appointmentForm.formState.errors.scheduledDate}
                  />
                )}
              />
              {appointmentForm.formState.errors.scheduledDate ? (
                <p className="text-xs text-danger">{t(appointmentForm.formState.errors.scheduledDate.message!)}</p>
              ) : null}
            </div>

            <div className="space-y-1.5">
              <Label>{t("customerApp.bookService.selectSlot")}</Label>
              {loadingSlots ? (
                <Skeleton className="h-16 w-full" />
              ) : activeSlots.length === 0 ? (
                <p className="rounded-xl border border-dashed border-border px-3.5 py-2.5 text-sm text-warning">
                  {t("customerApp.bookService.noSlotsConfigured")}
                </p>
              ) : bookableSlots.length === 0 ? (
                <p className="rounded-xl border border-dashed border-border px-3.5 py-2.5 text-sm text-warning">
                  {t("customerApp.bookService.noSlotsLeftToday")}
                </p>
              ) : (
                <div className="grid grid-cols-1 gap-2 sm:grid-cols-3">
                  {bookableSlots.map((s) => (
                    <button
                      key={s.id}
                      type="button"
                      onClick={() => appointmentForm.setValue("slotId", s.id, { shouldValidate: true })}
                      aria-pressed={appointmentForm.watch("slotId") === s.id}
                      className={`rounded-xl border px-3.5 py-2.5 text-left transition-colors ${
                        appointmentForm.watch("slotId") === s.id ? "border-accent bg-accent-soft" : "border-border"
                      }`}
                    >
                      <span className="block text-sm font-semibold text-text">{s.name}</span>
                      <span className="block text-xs text-text-muted">
                        {s.start_time.slice(0, 5)}–{s.end_time.slice(0, 5)}
                      </span>
                    </button>
                  ))}
                </div>
              )}
              {appointmentForm.formState.errors.slotId ? (
                <p className="text-xs text-warning">{t(appointmentForm.formState.errors.slotId.message!)}</p>
              ) : null}
            </div>
          </div>
          <label className="flex items-center gap-2 text-sm text-text">
            <input type="checkbox" {...appointmentForm.register("autoAssign")} className="size-4 rounded border-border" />
            {t("service.newComplaint.autoAssign")}
          </label>

          <div className="space-y-1.5">
            <Label>{t("common.referredByTechnician")}</Label>
            <select
              value={referredByTechnicianId}
              onChange={(e) => setReferredByTechnicianId(e.target.value)}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
            >
              <option value="">{t("common.none")}</option>
              {(technicians ?? []).map((tech) => (
                <option key={tech.id} value={tech.id}>
                  {tech.full_name}
                </option>
              ))}
            </select>
          </div>

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
