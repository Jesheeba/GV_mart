import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { CheckCircle2, Loader2, Plus, Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Stepper } from "@/components/shared/Stepper"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { PhotoCapture } from "../components/PhotoCapture"
import { SignaturePad } from "../components/SignaturePad"
import { SpareSelectStep, type SelectedSpare } from "./SpareSelectStep"
import { useProfile } from "@/hooks/useProfile"
import {
  useCacheVisitSignature,
  useCreateServiceInvoice,
  useEndVisit,
  useGenerateEnquiry,
  useJobDetail,
  useMyTechnician,
  useQueueRoChecklist,
  useQueueSopStepComplete,
  useQueueVisitImage,
  useStartVisit,
  useTechnicianSettings,
} from "@/hooks/useTechnician"
import { isChargeableTicketType } from "@/services/technician"
import { discountNeedsApproval, isDiscountBlocked, roChecklistSchema, servicePaymentSchema, enquiryLeadSchema } from "@/lib/validation/technician"
import { formatCurrency } from "@/lib/sale-calc"
import { startSyncEngine } from "@/lib/offline/sync"
import type { Enums } from "@/types/database"

const STEP_KEYS = ["sop", "spares", "charges", "ro", "invoice", "signatures", "payment"] as const
type SopStep = { id: string; name: string; expectedMinutes: number; doneAt: string | null }

function useVisitTimer(startedAt: number | null) {
  const [elapsedSec, setElapsedSec] = useState(0)
  useEffect(() => {
    if (!startedAt) return
    const interval = setInterval(() => setElapsedSec(Math.floor((Date.now() - startedAt) / 1000)), 1000)
    return () => clearInterval(interval)
  }, [startedAt])
  return elapsedSec
}

export function OnSiteVisitPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { ticketId } = useParams<{ ticketId: string }>()
  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const jobDetail = useJobDetail(ticketId)

  const startVisit = useStartVisit()
  const queueVisitImage = useQueueVisitImage()
  const queueSopStepComplete = useQueueSopStepComplete()
  const queueRoChecklist = useQueueRoChecklist()
  const createInvoice = useCreateServiceInvoice()
  const generateEnquiry = useGenerateEnquiry()
  const endVisit = useEndVisit()
  const cacheSignature = useCacheVisitSignature()

  const [visitId, setVisitId] = useState<string | null>(null)
  const [startedAt, setStartedAt] = useState<number | null>(null)
  const elapsedSec = useVisitTimer(startedAt)

  const [beforeImage, setBeforeImage] = useState<string | null>(null)
  const [afterImage, setAfterImage] = useState<string | null>(null)
  const [sopSteps, setSopSteps] = useState<SopStep[]>([])
  const [newStepName, setNewStepName] = useState("")
  const [newStepMinutes, setNewStepMinutes] = useState("10")

  const [selectedSpares, setSelectedSpares] = useState<SelectedSpare[]>([])
  const [discountInput, setDiscountInput] = useState("0")
  const [serviceChargeInput, setServiceChargeInput] = useState("0")

  const [tdsBefore, setTdsBefore] = useState("")
  const [tdsAfter, setTdsAfter] = useState("")
  const [tankCleaned, setTankCleaned] = useState<boolean | null>(null)
  const [productExplained, setProductExplained] = useState<boolean | null>(null)
  const [roClientName, setRoClientName] = useState("")

  const [techSign, setTechSign] = useState<string | null>(null)
  const [customerSign, setCustomerSign] = useState<string | null>(null)

  const [paymentMethod, setPaymentMethod] = useState<Enums<"payment_method">>("cash")
  const [txnId, setTxnId] = useState("")
  const [paymentDescription, setPaymentDescription] = useState("")
  const [paymentError, setPaymentError] = useState<string | null>(null)

  const [step, setStep] = useState(0)
  const [invoiceQueued, setInvoiceQueued] = useState(false)
  const [showEnquiry, setShowEnquiry] = useState(false)
  const [enquiryName, setEnquiryName] = useState("")
  const [enquiryMobile, setEnquiryMobile] = useState("")
  const [enquiryType, setEnquiryType] = useState<Enums<"enquiry_type">>("online")
  const [enquiryNote, setEnquiryNote] = useState("")
  const [enquirySent, setEnquirySent] = useState(false)

  // Idempotent — guards its own "already started" flag — so this is safe even
  // if this screen ends up routed outside TechnicianShell (a full-screen
  // stepper pushed on top, per the BuildSpec), where the shell's own
  // startSyncEngine() call wouldn't otherwise run.
  useEffect(() => {
    startSyncEngine()
  }, [])

  // Arrival: if the technician came from TECH-04's "I've arrived", a timer may
  // already be conceptually running (client-only, not persisted across a full
  // reload); starting the visit here (once) is what actually creates the
  // service_visits row + timer_start that the invoice is built against.
  useEffect(() => {
    if (!ticketId || !technician.data || !profile || visitId) return
    const id = crypto.randomUUID()
    const nowIso = new Date().toISOString()
    setVisitId(id)
    setStartedAt(Date.now())
    void startVisit.mutateAsync({ id, orgId: profile.org_id, ticketId, technicianId: technician.data.id, timerStart: nowIso })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ticketId, technician.data, profile])

  const ticket = jobDetail.data
  const chargeable = ticket ? isChargeableTicketType(ticket.type) : false
  const isRo = ticket?.products?.category === "ro"

  useEffect(() => {
    if (!chargeable) setServiceChargeInput("0")
  }, [chargeable])

  if (technician.isLoading || settings.isLoading || jobDetail.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (jobDetail.isError || !ticket) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }
  if (settings.isError || !settings.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => settings.refetch()} retryLabel={t("common.retry")} />
  }

  const techMax = Number(settings.data.discount_tech_max)
  const adminMax = Number(settings.data.discount_admin_max)
  const discountPercent = Math.max(0, Number(discountInput) || 0)
  const serviceCharge = chargeable ? Math.max(0, Number(serviceChargeInput) || 0) : 0

  const spareLinesTotal = selectedSpares.reduce((sum, s) => sum + (chargeable ? s.price * s.qty : 0), 0)
  const subtotal = serviceCharge + spareLinesTotal
  const discountAmount = (subtotal * discountPercent) / 100
  const invoiceTotal = Math.max(0, subtotal - discountAmount)

  const steps = STEP_KEYS.filter((k) => k !== "ro" || isRo).map((key) => ({ key, label: t(`technician.onsite.steps.${key}`) }))
  const activeStepKeys = STEP_KEYS.filter((k) => k !== "ro" || isRo)
  const currentKey = activeStepKeys[step]

  const sopAllDone = sopSteps.length > 0 && sopSteps.every((s) => s.doneAt)
  const roValid = !isRo || roChecklistSchema.safeParse({
    tdsBefore: tdsBefore === "" ? undefined : Number(tdsBefore),
    tdsAfter: tdsAfter === "" ? undefined : Number(tdsAfter),
    tankCleaned,
    productExplained,
    clientName: roClientName,
  }).success

  function canAdvanceFrom(key: (typeof STEP_KEYS)[number]) {
    if (key === "sop") return !!beforeImage && sopAllDone && !!afterImage
    if (key === "spares") return true
    if (key === "charges") return !isDiscountBlocked(discountPercent, adminMax)
    if (key === "ro") return roValid
    if (key === "invoice") return invoiceQueued
    if (key === "signatures") return !!techSign && !!customerSign
    return true
  }

  async function toggleSopStep(s: SopStep) {
    if (s.doneAt || !visitId || !profile) return
    const doneAt = new Date().toISOString()
    setSopSteps((prev) => prev.map((p) => (p.id === s.id ? { ...p, doneAt } : p)))
    await queueSopStepComplete.mutateAsync({ id: s.id, orgId: profile.org_id, visitId, stepName: s.name, expectedMinutes: s.expectedMinutes, doneAt })
  }

  function addSopStep() {
    const name = newStepName.trim()
    if (!name) return
    setSopSteps((prev) => [...prev, { id: crypto.randomUUID(), name, expectedMinutes: Math.max(1, Number(newStepMinutes) || 1), doneAt: null }])
    setNewStepName("")
    setNewStepMinutes("10")
  }

  function removeSopStep(id: string) {
    setSopSteps((prev) => prev.filter((s) => s.id !== id))
  }

  async function handleBeforeImage(dataUrl: string) {
    setBeforeImage(dataUrl)
    if (visitId) await queueVisitImage.mutateAsync({ visitId, kind: "before", url: dataUrl })
  }
  async function handleAfterImage(dataUrl: string) {
    setAfterImage(dataUrl)
    if (visitId) await queueVisitImage.mutateAsync({ visitId, kind: "after", url: dataUrl })
  }

  async function handleCreateInvoice() {
    if (!visitId || !profile) return
    await createInvoice.mutateAsync({
      orgId: profile.org_id,
      visitId,
      serviceCharge,
      discountPercent,
      spares: selectedSpares.map((s) => ({ spareId: s.spareId, qty: s.qty })),
      paymentMethod,
      txnId: paymentMethod === "transfer" ? txnId : undefined,
      paymentDescription: paymentMethod === "transfer" ? paymentDescription : undefined,
      isChargeable: chargeable,
    })
    setInvoiceQueued(true)
  }

  async function handleRoSave() {
    if (!visitId || !profile) return
    await queueRoChecklist.mutateAsync({
      orgId: profile.org_id,
      visitId,
      tdsBefore: tdsBefore === "" ? undefined : Number(tdsBefore),
      tdsAfter: tdsAfter === "" ? undefined : Number(tdsAfter),
      tankCleaned,
      productExplained,
      clientName: roClientName,
    })
  }

  async function handlePaymentSubmit() {
    const result = servicePaymentSchema.safeParse({ method: paymentMethod, txnId, description: paymentDescription })
    if (!result.success) {
      setPaymentError(result.error.issues[0]?.message ?? "technician.errors.paymentInvalid")
      return
    }
    setPaymentError(null)
    if (visitId) await endVisit.mutateAsync({ visitId, timerEnd: new Date().toISOString() })
    navigate(`/technician/jobs/${ticketId}/rating`, { state: { visitId } })
  }

  function handleTechSign(dataUrl: string | null) {
    setTechSign(dataUrl)
    if (dataUrl && visitId) void cacheSignature.mutateAsync({ visitId, kind: "signature_tech", dataUrl })
  }

  function handleCustomerSign(dataUrl: string | null) {
    setCustomerSign(dataUrl)
    if (dataUrl && visitId) void cacheSignature.mutateAsync({ visitId, kind: "signature_customer", dataUrl })
  }

  async function handleSendEnquiry() {
    if (!profile) return
    const parsed = enquiryLeadSchema.safeParse({ name: enquiryName, mobile: enquiryMobile, enquiryType, note: enquiryNote })
    if (!parsed.success) return
    if (!ticket) return
    await generateEnquiry.mutateAsync({
      orgId: profile.org_id,
      customerId: ticket.customer_id,
      name: parsed.data.name,
      mobile: parsed.data.mobile || undefined,
      enquiryType: parsed.data.enquiryType,
      note: parsed.data.note || undefined,
    })
    setEnquirySent(true)
  }

  const minutes = String(Math.floor(elapsedSec / 60)).padStart(2, "0")
  const seconds = String(elapsedSec % 60).padStart(2, "0")

  return (
    <div className="space-y-4 pt-2 pb-8">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("technician.onsite.title")}</h1>
        <span className="rounded-full bg-ink px-3 py-1 font-mono text-sm font-semibold text-white">
          {minutes}:{seconds}
        </span>
      </div>
      <p className="px-1 text-sm text-text-muted">{ticket.customers?.name} — {ticket.products?.name ?? ticket.name_of_complaint}</p>

      <Card>
        <Stepper steps={steps} currentIndex={step} />
      </Card>

      {currentKey === "sop" ? (
        <div className="space-y-4">
          <PhotoCapture label={t("technician.onsite.beforeImage")} dataUrl={beforeImage} onCaptured={handleBeforeImage} />

          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.sopTitle")}</p>
            <p className="px-1 text-xs text-text-muted">{t("technician.onsite.sopHint")}</p>
            {sopSteps.length === 0 ? (
              <p className="px-1 text-sm text-text-muted">{t("technician.onsite.sopEmpty")}</p>
            ) : (
              <div className="space-y-2">
                {sopSteps.map((s) => (
                  <div key={s.id} className="flex items-center gap-2.5 rounded-xl border border-border px-3.5 py-2.5">
                    <button
                      type="button"
                      onClick={() => toggleSopStep(s)}
                      disabled={!!s.doneAt}
                      className="flex size-6 shrink-0 items-center justify-center rounded-full bg-surface-alt text-text-muted disabled:opacity-100"
                    >
                      {s.doneAt ? <CheckCircle2 className="size-5 text-success" /> : null}
                    </button>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-text">{s.name}</p>
                      <p className="text-xs text-text-muted">{t("technician.onsite.sopExpected", { minutes: s.expectedMinutes })}</p>
                    </div>
                    {!s.doneAt ? (
                      <Button type="button" variant="ghost" size="icon-sm" onClick={() => removeSopStep(s.id)}>
                        <Trash2 className="size-3.5 text-danger" />
                      </Button>
                    ) : null}
                  </div>
                ))}
              </div>
            )}
            <div className="flex items-end gap-2 px-1">
              <div className="flex-1 space-y-1">
                <Label htmlFor="stepName">{t("technician.onsite.sopStepName")}</Label>
                <Input id="stepName" value={newStepName} onChange={(e) => setNewStepName(e.target.value)} placeholder={t("technician.onsite.sopStepNamePlaceholder")} />
              </div>
              <div className="w-20 space-y-1">
                <Label htmlFor="stepMinutes">{t("technician.onsite.sopStepMinutes")}</Label>
                <Input id="stepMinutes" type="number" min={1} value={newStepMinutes} onChange={(e) => setNewStepMinutes(e.target.value)} />
              </div>
              <Button type="button" variant="outline" size="icon" onClick={addSopStep}>
                <Plus className="size-4" />
              </Button>
            </div>
          </Card>

          <PhotoCapture label={t("technician.onsite.afterImage")} dataUrl={afterImage} onCaptured={handleAfterImage} />
        </div>
      ) : null}

      {currentKey === "spares" ? <SpareSelectStep orgId={profile?.org_id} selected={selectedSpares} onChange={setSelectedSpares} /> : null}

      {currentKey === "charges" ? (
        <Card className="gap-3">
          <div className="space-y-1.5 px-1">
            <Label htmlFor="serviceCharge">{t("technician.onsite.charges.serviceCharge")}</Label>
            <Input id="serviceCharge" type="number" min={0} value={serviceChargeInput} onChange={(e) => setServiceChargeInput(e.target.value)} disabled={!chargeable} />
            {!chargeable ? <p className="text-xs text-text-muted">{t("technician.onsite.charges.notChargeableNote", { type: t(`service.type.${ticket.type ?? "warranty"}`) })}</p> : null}
          </div>

          <div className="space-y-1.5 px-1">
            <Label htmlFor="discount">{t("technician.onsite.charges.discountLabel")}</Label>
            <Input id="discount" type="number" min={0} max={adminMax} step="0.5" value={discountInput} onChange={(e) => setDiscountInput(e.target.value)} className="w-32" />
            <p className="text-xs text-text-muted">{t("technician.onsite.charges.freeUpTo", { max: techMax })}</p>
            <p className="text-xs text-warning">{t("technician.onsite.charges.approvalBand", { min: techMax, max: adminMax })}</p>
            <p className="text-xs text-danger">{t("technician.onsite.charges.blockedAbove", { max: adminMax })}</p>
            {isDiscountBlocked(discountPercent, adminMax) ? (
              <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{t("technician.onsite.charges.blockedMessage", { max: adminMax })}</p>
            ) : discountNeedsApproval(discountPercent, techMax, adminMax) ? (
              <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-sm text-warning">{t("technician.onsite.charges.needsApprovalMessage")}</p>
            ) : null}
          </div>

          <div className="space-y-1 px-1 text-sm">
            <div className="flex justify-between"><span className="text-text-muted">{t("technician.onsite.charges.subtotal")}</span><span className="text-text">{formatCurrency(subtotal)}</span></div>
            <div className="flex justify-between"><span className="text-text-muted">{t("technician.onsite.charges.discountAmount")}</span><span className="text-text">-{formatCurrency(discountAmount)}</span></div>
            <div className="flex justify-between font-semibold"><span className="text-text">{t("technician.onsite.charges.total")}</span><span className="text-text">{formatCurrency(invoiceTotal)}</span></div>
          </div>
        </Card>
      ) : null}

      {currentKey === "ro" ? (
        <Card className="gap-3">
          <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.ro.title")}</p>
          <div className="grid grid-cols-2 gap-3 px-1">
            <div className="space-y-1.5">
              <Label htmlFor="tdsBefore">{t("technician.onsite.ro.tdsBefore")}</Label>
              <Input id="tdsBefore" type="number" min={0} value={tdsBefore} onChange={(e) => setTdsBefore(e.target.value)} />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="tdsAfter">{t("technician.onsite.ro.tdsAfter")}</Label>
              <Input id="tdsAfter" type="number" min={0} value={tdsAfter} onChange={(e) => setTdsAfter(e.target.value)} />
            </div>
          </div>
          <div className="space-y-1.5 px-1">
            <Label>{t("technician.onsite.ro.tankCleaned")}</Label>
            <div className="flex gap-2">
              {[true, false].map((v) => (
                <Button key={String(v)} type="button" size="sm" variant={tankCleaned === v ? "default" : "outline"} onClick={() => setTankCleaned(v)}>
                  {v ? t("common.yes") : t("common.no")}
                </Button>
              ))}
            </div>
          </div>
          <div className="space-y-1.5 px-1">
            <Label>{t("technician.onsite.ro.productExplained")}</Label>
            <div className="flex gap-2">
              {[true, false].map((v) => (
                <Button key={String(v)} type="button" size="sm" variant={productExplained === v ? "default" : "outline"} onClick={() => setProductExplained(v)}>
                  {v ? t("common.yes") : t("common.no")}
                </Button>
              ))}
            </div>
          </div>
          <div className="space-y-1.5 px-1">
            <Label htmlFor="roClientName">{t("technician.onsite.ro.clientName")}</Label>
            <Input id="roClientName" value={roClientName} onChange={(e) => setRoClientName(e.target.value)} />
          </div>
          <Button type="button" variant="outline" onClick={handleRoSave} disabled={!roValid || queueRoChecklist.isPending}>
            {queueRoChecklist.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.onsite.ro.save")}
          </Button>
        </Card>
      ) : null}

      {currentKey === "invoice" ? (
        <Card className="gap-3">
          <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.invoice.title")}</p>
          <div className="space-y-1 px-1 text-sm">
            {chargeable ? (
              <div className="flex justify-between"><span className="text-text-muted">{t("technician.onsite.charges.serviceCharge")}</span><span className="text-text">{formatCurrency(serviceCharge)}</span></div>
            ) : (
              <div className="flex justify-between"><span className="text-text-muted">{t("technician.onsite.charges.serviceCharge")}</span><span className="text-text">{formatCurrency(0)}</span></div>
            )}
            {selectedSpares.map((s) => (
              <div key={s.spareId} className="flex justify-between text-text-muted">
                <span>{s.name} × {s.qty}</span>
                <span>{formatCurrency(chargeable ? s.price * s.qty : 0)}</span>
              </div>
            ))}
            <div className="flex justify-between border-t border-border pt-1 font-semibold"><span className="text-text">{t("technician.onsite.charges.total")}</span><span className="text-text">{formatCurrency(invoiceTotal)}</span></div>
          </div>
          {!chargeable ? <p className="px-1 text-xs text-text-muted">{t("technician.jobDetail.costingRuleFree")}</p> : null}

          {invoiceQueued ? (
            <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
              <CheckCircle2 className="size-4" /> {t("technician.onsite.invoice.queued")}
            </p>
          ) : (
            <Button type="button" onClick={handleCreateInvoice} disabled={createInvoice.isPending || !visitId}>
              {createInvoice.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.onsite.invoice.create")}
            </Button>
          )}
          {createInvoice.isError ? <p className="px-1 text-xs text-danger">{t("technician.errors.loadFailed")}</p> : null}
        </Card>
      ) : null}

      {currentKey === "signatures" ? (
        <div className="space-y-4">
          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.signatures.techTitle")}</p>
            <SignaturePad onChange={handleTechSign} />
          </Card>
          <Card className="gap-3">
            <p className="px-1 text-sm font-semibold text-text">{t("technician.onsite.signatures.customerTitle")}</p>
            <SignaturePad onChange={handleCustomerSign} />
          </Card>
        </div>
      ) : null}

      {currentKey === "payment" ? (
        <Card className="gap-3">
          <Label>{t("technician.onsite.payment.method")}</Label>
          <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1">
            {(["cash", "transfer"] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => setPaymentMethod(m)}
                className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${paymentMethod === m ? "bg-ink text-white" : "text-text-muted"}`}
              >
                {t(`technician.onsite.payment.${m}`)}
              </button>
            ))}
          </div>
          {paymentMethod === "transfer" ? (
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div className="space-y-1.5">
                <Label htmlFor="txnId">{t("technician.onsite.payment.txnId")}</Label>
                <Input id="txnId" value={txnId} onChange={(e) => setTxnId(e.target.value)} />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="paymentDescription">{t("technician.onsite.payment.description")}</Label>
                <Input id="paymentDescription" value={paymentDescription} onChange={(e) => setPaymentDescription(e.target.value)} />
              </div>
            </div>
          ) : null}
          <p className="text-xs text-text-muted">{t("technician.onsite.payment.noGatewayNote")}</p>
          {paymentError ? <p className="text-xs text-danger">{t(paymentError)}</p> : null}

          <Button type="button" onClick={handlePaymentSubmit}>
            {t("technician.onsite.payment.complete")}
          </Button>
        </Card>
      ) : null}

      <Card className="gap-2.5">
        <button type="button" className="px-1 text-left text-sm font-semibold text-accent" onClick={() => setShowEnquiry((v) => !v)}>
          {t("technician.onsite.enquiry.toggle")}
        </button>
        {showEnquiry ? (
          enquirySent ? (
            <p className="px-1 text-sm text-success">{t("technician.onsite.enquiry.sent")}</p>
          ) : (
            <div className="space-y-2.5 px-1">
              <Input value={enquiryName} onChange={(e) => setEnquiryName(e.target.value)} placeholder={t("technician.onsite.enquiry.namePlaceholder")} />
              <Input value={enquiryMobile} onChange={(e) => setEnquiryMobile(e.target.value)} placeholder={t("technician.onsite.enquiry.mobilePlaceholder")} />
              <select
                value={enquiryType}
                onChange={(e) => setEnquiryType(e.target.value as Enums<"enquiry_type">)}
                className="h-10 w-full rounded-xl border border-border bg-surface px-3.5 text-sm text-text outline-none"
              >
                {(["online", "price", "quality", "customization", "water_premium", "budget"] as const).map((et) => (
                  <option key={et} value={et}>{t(`technician.onsite.enquiry.type.${et}`)}</option>
                ))}
              </select>
              <Input value={enquiryNote} onChange={(e) => setEnquiryNote(e.target.value)} placeholder={t("technician.onsite.enquiry.notePlaceholder")} />
              <Button type="button" variant="outline" onClick={handleSendEnquiry} disabled={generateEnquiry.isPending || !enquiryName.trim()}>
                {generateEnquiry.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.onsite.enquiry.send")}
              </Button>
            </div>
          )
        ) : null}
      </Card>

      <div className="flex justify-between">
        <Button type="button" variant="outline" onClick={() => (step === 0 ? navigate(-1) : setStep(step - 1))}>
          {step === 0 ? t("common.cancel") : t("common.back")}
        </Button>
        {currentKey !== "payment" ? (
          <Button type="button" disabled={!canAdvanceFrom(currentKey)} onClick={() => setStep(step + 1)}>
            {t("technician.onsite.next")}
          </Button>
        ) : null}
      </div>
    </div>
  )
}
