import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { zodResolver } from "@hookform/resolvers/zod"
import { useForm } from "react-hook-form"
import { Loader2, Search, ShieldCheck, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import { Stepper } from "@/components/shared/Stepper"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { brandsHooks, modelsHooks, productsHooks } from "@/hooks/useMasters"
import {
  useCreateComplaintTicket,
  useCustomerAddresses,
  useDetectTicketType,
  useOwnedEquipment,
} from "@/hooks/useService"
import {
  complaintAppointmentStepSchema,
  complaintDetailsStepSchema,
  type ComplaintAppointmentStepInput,
  type ComplaintDetailsStepInput,
} from "@/lib/validation/service"
import { TicketTypeBadge } from "./TicketBadges"

const PRIORITIES = ["very_urgent", "urgent", "normal"] as const

export function NewComplaintPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const [step, setStep] = useState(0)

  // Step 1: customer
  const [customerSearch, setCustomerSearch] = useState("")
  const [customerId, setCustomerId] = useState("")
  const [customerLabel, setCustomerLabel] = useState("")
  const customerAutocomplete = useCustomerAutocomplete(orgId, customerSearch)

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

  // Step 3: complaint details
  const detailsForm = useForm<ComplaintDetailsStepInput>({
    resolver: zodResolver(complaintDetailsStepSchema),
    mode: "onChange",
    defaultValues: { nameOfComplaint: "", natureOfComplaint: "", priority: "normal" },
  })

  // Step 4: type auto-detect
  const detected = useDetectTicketType(orgId, customerId, resolvedProductId || null)

  // Step 5: appointment
  const appointmentForm = useForm<ComplaintAppointmentStepInput>({
    resolver: zodResolver(complaintAppointmentStepSchema),
    mode: "onChange",
    defaultValues: { mode: "always", scheduledAt: "", autoAssign: true },
  })

  const createTicket = useCreateComplaintTicket()

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
    setStep((s) => Math.min(s + 1, steps.length - 1))
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
      scheduledAt: appt.mode === "datetime" && appt.scheduledAt ? new Date(appt.scheduledAt).toISOString() : null,
      autoAssign: appt.autoAssign,
    })
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

      <Card>
        <Stepper steps={steps} currentIndex={step} />
      </Card>

      {step === 0 ? (
        <Card className="gap-3">
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
            }}
          />
          {!customerId ? <p className="text-xs text-text-muted">{t("service.newComplaint.customerSearchHint")}</p> : null}
        </Card>
      ) : null}

      {step === 1 ? (
        <Card className="gap-3">
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
        <Card className="gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="nameOfComplaint">{t("service.newComplaint.nameOfComplaint")}</Label>
            <Input
              id="nameOfComplaint"
              placeholder={t("service.newComplaint.nameOfComplaintPlaceholder")}
              aria-invalid={!!detailsForm.formState.errors.nameOfComplaint}
              {...detailsForm.register("nameOfComplaint")}
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
        <Card className="gap-3">
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
        <Card className="gap-3">
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
        <Card className="gap-3">
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
            <div className="space-y-1.5">
              <Label htmlFor="scheduledAt">{t("service.newComplaint.scheduledAt")}</Label>
              <Input
                id="scheduledAt"
                type="datetime-local"
                aria-invalid={!!appointmentForm.formState.errors.scheduledAt}
                {...appointmentForm.register("scheduledAt")}
              />
              <p className="text-xs text-text-muted">{t("service.newComplaint.workHoursHint")}</p>
              {appointmentForm.formState.errors.scheduledAt ? (
                <p className="text-xs text-danger">{t(appointmentForm.formState.errors.scheduledAt.message!)}</p>
              ) : null}
            </div>
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
