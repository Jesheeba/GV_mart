import { useEffect, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { CheckCircle2, Loader2, Plus, Save, Trash2, TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"
import { Stepper } from "@/components/shared/Stepper"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useToast } from "@/components/ui/toast-context"
import { PhotoCapture } from "../components/PhotoCapture"
import { SignaturePad } from "../components/SignaturePad"
import { VoiceNoteRecorder } from "../components/VoiceNoteRecorder"
import { SpareSelectStep, type SelectedSpare } from "./SpareSelectStep"
import { SellAmcSection } from "./SellAmcSection"
import { useProfile } from "@/hooks/useProfile"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { sopStepTemplatesHooks } from "@/hooks/useMasters"
import {
  useCacheVisitSignature,
  useCacheVisitVoiceNote,
  useCreateServiceInvoice,
  useGenerateEnquiry,
  useGenerateVisitOtp,
  useJobDetail,
  useMyTechnician,
  useQueueRoChecklist,
  useQueueSopStepComplete,
  useQueueVisitEvidencePhotos,
  useQueueVisitImage,
  useTechnicianSettings,
  useVerifyVisitOtp,
} from "@/hooks/useTechnician"
import { findOpenVisit, isChargeableTicketType, isTicketClosed } from "@/services/technician"
import { discountNeedsApproval, isDiscountBlocked, roChecklistSchema, servicePaymentSchema, enquiryLeadSchema } from "@/lib/validation/technician"
import { formatCurrency } from "@/lib/sale-calc"
import { db } from "@/lib/offline/db"
import { startSyncEngine } from "@/lib/offline/sync"
import type { Enums } from "@/types/database"

// GV.md 1.1/D4: the SOP checklist is now populated from the job's actual
// inventory items (each carrying its admin-set standard time), not free
// text — which means item selection has to happen BEFORE the checklist can
// be built from it. "spares" moved ahead of "sop" for exactly that reason
// (previously sop→spares); the before-photo capture that used to open the
// flow now happens one step later, bundled into the "sop" screen as before —
// see the sync effect below for how sopSteps gets seeded from selectedSpares.
const STEP_KEYS = ["spares", "sop", "charges", "ro", "afterphoto", "invoice", "signatures", "payment"] as const
// `spareId` is set only for a step auto-derived from a selected spare (GV.md
// 1.1/D4) — undefined means a technician-added free-text step (still
// supported: a "SOP master" screen covering every possible task, e.g. a
// diagnostic step with no matching spare, is explicitly out of v2.2 scope —
// see the existing sopAllDone comment below). Purely a local reconciliation
// key; service_sop_steps has no spare_id column, so it never gets queued.
type SopStep = { id: string; name: string; expectedMinutes: number; doneAt: string | null; spareId?: string }
/** Fallback expected-minutes for a spare with no standard_time_minutes set yet (GV.md 1.1: null = "not yet timed" by admin). */
const DEFAULT_SOP_STEP_MINUTES = 10

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

/**
 * Everything in the stepper that has no server representation until its own
 * section's explicit save button is tapped — SOP items not yet marked done,
 * spares picked but no invoice created yet, typed-but-unsaved charges/RO
 * fields, captured-but-unsynced photos/signatures, which step/payment
 * fields, and the enquiry sub-form. Snapshotted into `visitFormDrafts` on
 * every change (debounced for text fields, immediate for discrete captures)
 * and restored on mount so navigating away and back — accidental or not —
 * never silently discards work in progress.
 */
type VisitDraftData = {
  beforeImage: string | null
  afterImage: string | null
  visitNotes: string
  voiceNoteUrl: string | null
  sopSteps: SopStep[]
  evidenceImages: string[]
  selectedSpares: SelectedSpare[]
  discountInput: string
  serviceChargeInput: string
  tdsBefore: string
  tdsAfter: string
  tankCleaned: boolean | null
  productExplained: boolean | null
  roClientName: string
  techSign: string | null
  customerSign: string | null
  paymentMethod: Enums<"payment_method">
  txnId: string
  paymentDescription: string
  step: number
  invoiceQueued: boolean
  showEnquiry: boolean
  enquiryName: string
  enquiryMobile: string
  enquiryType: Enums<"enquiry_type">
  enquiryNote: string
}

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
  const { toast } = useToast()
  const navigate = useNavigate()
  const { ticketId } = useParams<{ ticketId: string }>()
  const { data: profile } = useProfile()
  const technician = useMyTechnician()
  const settings = useTechnicianSettings(profile?.org_id)
  const jobDetail = useJobDetail(ticketId)
  const sopStepTemplatesQuery = sopStepTemplatesHooks.useList(profile?.org_id)

  const queueVisitImage = useQueueVisitImage()
  const queueVisitEvidencePhotos = useQueueVisitEvidencePhotos()
  const queueSopStepComplete = useQueueSopStepComplete()
  const queueRoChecklist = useQueueRoChecklist()
  const createInvoice = useCreateServiceInvoice()
  const generateEnquiry = useGenerateEnquiry()
  const generateOtp = useGenerateVisitOtp()
  const verifyOtp = useVerifyVisitOtp()
  const cacheSignature = useCacheVisitSignature()
  const cacheVoiceNote = useCacheVisitVoiceNote()

  const [visitId, setVisitId] = useState<string | null>(null)
  const [startedAt, setStartedAt] = useState<number | null>(null)
  const elapsedSec = useVisitTimer(startedAt)

  const [beforeImage, setBeforeImage] = useState<string | null>(null)
  const [afterImage, setAfterImage] = useState<string | null>(null)
  // Task 6 — extra evidence beyond the single before/after image (damaged/
  // replaced/installed parts). Same "local state + draft, queued per change"
  // pattern as beforeImage/afterImage above.
  const [evidenceImages, setEvidenceImages] = useState<string[]>([])
  const [visitNotes, setVisitNotes] = useState("")
  const [voiceNoteUrl, setVoiceNoteUrl] = useState<string | null>(null)
  const [sopSteps, setSopSteps] = useState<SopStep[]>([])
  // Task 5 — SOP steps not covered by a spare are picked from an admin-
  // curated list (sop_step_templates), never free-typed. Transient UI
  // selection only, not part of VisitDraftData: unlike sopSteps (the actual
  // added/completed steps), which picker option is currently highlighted has
  // no meaning to restore across a page reload.
  const [selectedTemplateId, setSelectedTemplateId] = useState("")

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

  // GV.md §2 — OTP completion confirmation. Deliberately NOT part of
  // VisitDraftData/local autosave: the code the technician types is
  // ephemeral input, never the source of truth (that lives server-side —
  // see the migration's design decisions), and otpGenerated tracks
  // "already requested a code for this visit" purely for this mounted
  // session so revisiting the Payment step doesn't spam generate_visit_otp.
  const [otpCode, setOtpCode] = useState("")
  const [otpErrorKey, setOtpErrorKey] = useState<string | null>(null)
  const [otpRemaining, setOtpRemaining] = useState<number | null>(null)
  const [otpGenerating, setOtpGenerating] = useState(false)
  const otpRequestedForVisitRef = useRef<string | null>(null)

  const [step, setStep] = useState(0)
  // Only ever grows — tracks the furthest step reached so navigating back
  // (which decreases `step`) doesn't make already-completed steps lose their
  // checkmark in the Stepper below. See Stepper's `maxCompletedIndex` doc.
  const [maxStepReached, setMaxStepReached] = useState(0)
  const [invoiceQueued, setInvoiceQueued] = useState(false)
  const [showEnquiry, setShowEnquiry] = useState(false)
  const [enquiryName, setEnquiryName] = useState("")
  const [enquiryMobile, setEnquiryMobile] = useState("")
  const [enquiryType, setEnquiryType] = useState<Enums<"enquiry_type">>("online")
  const [enquiryNote, setEnquiryNote] = useState("")
  const [enquirySent, setEnquirySent] = useState(false)

  const [draftHydrated, setDraftHydrated] = useState(false)
  const [draftRestored, setDraftRestored] = useState(false)
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false)
  const hydratingTicketRef = useRef<string | null>(null)
  // Set right before discardDraft() resets every field to its default —
  // without this, the reset itself changes draftSnapshot, and ~500ms later
  // the still-active autosave effect below would dutifully write that
  // all-defaults snapshot right back to Dexie, resurrecting an empty draft
  // moments after the technician explicitly deleted it.
  const suppressNextAutosaveRef = useRef(false)

  // Idempotent — guards its own "already started" flag — so this is safe even
  // if this screen ends up routed outside TechnicianShell (a full-screen
  // stepper pushed on top, per the BuildSpec), where the shell's own
  // startSyncEngine() call wouldn't otherwise run.
  useEffect(() => {
    startSyncEngine()
  }, [])

  // Arrival: MapPage's arrival detection (auto or the "I've arrived"
  // fallback tap) is the only place a service_visits row is created, so this
  // page can be reached with one already open for this ticket — adopt it.
  // Task 4 — arrival confirmation is mandatory: this page must NEVER create
  // a visit itself. If none exists yet (e.g. a stale URL, or JobDetailPage's
  // "Start visit" reached this route before its own guard was added), redirect
  // back to the arrival-confirmation screen instead of silently starting a
  // visit with no geofence check. A closed ticket (stale URL/browser-back
  // into a finished job) also skips this — the render below shows a blocking
  // "already closed" state instead.
  useEffect(() => {
    if (!ticketId || !jobDetail.data || visitId) return
    const existing = findOpenVisit(jobDetail.data.service_visits)
    if (existing) {
      setVisitId(existing.id)
      setStartedAt(new Date(existing.timer_start!).getTime())
      return
    }
    if (isTicketClosed(jobDetail.data.status)) return
    toast.error(t("technician.onsite.arrivalRequired"))
    navigate(`/technician/map?ticketId=${ticketId}`, { replace: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ticketId, jobDetail.data, visitId])

  // Restores whatever was locally saved for this ticket before rendering
  // proceeds any further — runs once per ticketId (guarded via the ref, not
  // state, so it can't fire twice from a render caused by its own restore).
  useEffect(() => {
    if (!ticketId || hydratingTicketRef.current === ticketId) return
    hydratingTicketRef.current = ticketId
    db.visitFormDrafts.get(ticketId).then((draft) => {
      if (!draft) {
        setDraftHydrated(true)
        return
      }
      const d = draft.data as Partial<VisitDraftData>
      if (d.beforeImage) setBeforeImage(d.beforeImage)
      if (d.afterImage) setAfterImage(d.afterImage)
      if (d.visitNotes) setVisitNotes(d.visitNotes)
      if (d.voiceNoteUrl) setVoiceNoteUrl(d.voiceNoteUrl)
      if (d.sopSteps?.length) setSopSteps(d.sopSteps)
      if (d.evidenceImages?.length) setEvidenceImages(d.evidenceImages)
      if (d.selectedSpares?.length) setSelectedSpares(d.selectedSpares)
      if (d.discountInput != null) setDiscountInput(d.discountInput)
      if (d.serviceChargeInput != null) setServiceChargeInput(d.serviceChargeInput)
      if (d.tdsBefore != null) setTdsBefore(d.tdsBefore)
      if (d.tdsAfter != null) setTdsAfter(d.tdsAfter)
      if (d.tankCleaned !== undefined) setTankCleaned(d.tankCleaned)
      if (d.productExplained !== undefined) setProductExplained(d.productExplained)
      if (d.roClientName) setRoClientName(d.roClientName)
      if (d.techSign) setTechSign(d.techSign)
      if (d.customerSign) setCustomerSign(d.customerSign)
      if (d.paymentMethod) setPaymentMethod(d.paymentMethod)
      if (d.txnId) setTxnId(d.txnId)
      if (d.paymentDescription) setPaymentDescription(d.paymentDescription)
      if (d.step != null) {
        const restoredStep = d.step
        setStep(restoredStep)
        setMaxStepReached((m) => Math.max(m, restoredStep))
      }
      if (d.invoiceQueued != null) setInvoiceQueued(d.invoiceQueued)
      if (d.showEnquiry != null) setShowEnquiry(d.showEnquiry)
      if (d.enquiryName) setEnquiryName(d.enquiryName)
      if (d.enquiryMobile) setEnquiryMobile(d.enquiryMobile)
      if (d.enquiryType) setEnquiryType(d.enquiryType)
      if (d.enquiryNote) setEnquiryNote(d.enquiryNote)
      setDraftRestored(true)
      setDraftHydrated(true)
    })
  }, [ticketId])

  // Debounced local autosave — covers every text/selection field that has no
  // server representation until its own section is explicitly saved (see
  // VisitDraftData's doc comment). Skipped until hydration has run once, so
  // restoring a draft can't immediately overwrite itself with the
  // pre-restore defaults it started from.
  const draftSnapshot: VisitDraftData = {
    beforeImage,
    afterImage,
    visitNotes,
    voiceNoteUrl,
    sopSteps,
    evidenceImages,
    selectedSpares,
    discountInput,
    serviceChargeInput,
    tdsBefore,
    tdsAfter,
    tankCleaned,
    productExplained,
    roClientName,
    techSign,
    customerSign,
    paymentMethod,
    txnId,
    paymentDescription,
    step,
    invoiceQueued,
    showEnquiry,
    enquiryName,
    enquiryMobile,
    enquiryType,
    enquiryNote,
  }
  const debouncedDraftKey = useDebouncedValue(JSON.stringify(draftSnapshot), 500)

  useEffect(() => {
    if (!ticketId || !draftHydrated) return
    if (suppressNextAutosaveRef.current) {
      suppressNextAutosaveRef.current = false
      return
    }
    void db.visitFormDrafts.put({ ticketId, visitId, data: JSON.parse(debouncedDraftKey), updatedAt: Date.now() })
  }, [debouncedDraftKey, ticketId, draftHydrated, visitId])

  async function discardDraft() {
    if (ticketId) await db.visitFormDrafts.delete(ticketId)
    suppressNextAutosaveRef.current = true
    setBeforeImage(null)
    setAfterImage(null)
    setVisitNotes("")
    setVoiceNoteUrl(null)
    setSopSteps([])
    setSelectedTemplateId("")
    setEvidenceImages([])
    setSelectedSpares([])
    setDiscountInput("0")
    setServiceChargeInput("0")
    setTdsBefore("")
    setTdsAfter("")
    setTankCleaned(null)
    setProductExplained(null)
    setRoClientName("")
    setTechSign(null)
    setCustomerSign(null)
    setPaymentMethod("cash")
    setTxnId("")
    setPaymentDescription("")
    setOtpCode("")
    setOtpErrorKey(null)
    setOtpRemaining(null)
    setStep(0)
    setMaxStepReached(0)
    setInvoiceQueued(false)
    setShowEnquiry(false)
    setEnquiryName("")
    setEnquiryMobile("")
    setEnquiryType("online")
    setEnquiryNote("")
    setEnquirySent(false)
    setDraftRestored(false)
    setShowDiscardConfirm(false)
  }

  const ticket = jobDetail.data
  const chargeable = ticket ? isChargeableTicketType(ticket.type) : false
  const isRo = ticket?.products?.category === "ro"

  // Task 5 — SOP steps not covered by a spare are picked from this
  // admin-curated list instead of free-typed: templates scoped to the
  // ticket's own product, plus org-wide generic ones (product_id null),
  // excluding a name already added to this visit's checklist so the picker
  // doesn't keep offering a step the technician already has.
  const addedStepNames = new Set(sopSteps.map((s) => s.name))
  const sopStepTemplates = (sopStepTemplatesQuery.data ?? []).filter(
    (tpl) => tpl.active && (tpl.product_id === null || tpl.product_id === ticket?.product_id) && !addedStepNames.has(tpl.name)
  )

  useEffect(() => {
    if (!chargeable) setServiceChargeInput("0")
  }, [chargeable])

  // GV.md §2 — request the completion code the moment the technician
  // reaches the Payment step (the last one), so the customer has the most
  // possible lead time before it's actually needed. Kept above the early
  // returns below, alongside every other hook in this component (rules of
  // hooks — this must run unconditionally every render). Computed here
  // rather than reusing the `currentKey` derived further down, since that
  // derivation happens after the loading/error guards and this effect must
  // not. Guarded by a ref (not state) keyed on visitId so revisiting this
  // step doesn't re-request a code the customer may already be reading out.
  const activeStepKeysForOtp = STEP_KEYS.filter((k) => k !== "ro" || isRo)
  const isOnPaymentStepForOtp = activeStepKeysForOtp[step] === "payment"
  useEffect(() => {
    if (!isOnPaymentStepForOtp || !visitId || !profile) return
    if (otpRequestedForVisitRef.current === visitId) return
    otpRequestedForVisitRef.current = visitId
    setOtpGenerating(true)
    generateOtp.mutate(
      { orgId: profile.org_id, visitId },
      {
        onSettled: () => setOtpGenerating(false),
        onError: () => {
          otpRequestedForVisitRef.current = null
          toast.error(t("technician.onsite.otp.errors.generateFailed"))
        },
      }
    )
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOnPaymentStepForOtp, visitId, profile])

  // GV.md 1.1/D4: reconciles the SOP checklist against the technician's
  // current spare selection — adds a checklist step (name + admin-set
  // standard time) for every selected spare that doesn't have one yet, and
  // drops a spare-derived step whose spare was deselected again (unless
  // it's already marked done — a completed step is never silently removed).
  // Technician-added free-text steps (spareId undefined) are left alone.
  // Runs on every selectedSpares change, not gated to the "spares"/"sop"
  // step, so the checklist is already correct by the time the technician
  // reaches it (including after a draft restore).
  useEffect(() => {
    setSopSteps((prev) => {
      const selectedIds = new Set(selectedSpares.map((sp) => sp.spareId))
      const existingBySpare = new Map(prev.filter((s) => s.spareId).map((s) => [s.spareId!, s]))
      // One step per currently-selected spare — reuses the existing step
      // (keeps its id/doneAt) when the technician already has one.
      const forSelected: SopStep[] = selectedSpares.map(
        (sp) =>
          existingBySpare.get(sp.spareId) ?? {
            id: crypto.randomUUID(),
            name: sp.name,
            expectedMinutes: sp.standardTimeMinutes ?? DEFAULT_SOP_STEP_MINUTES,
            doneAt: null,
            spareId: sp.spareId,
          }
      )
      // A spare-derived step whose spare was deselected again is dropped —
      // unless it's already marked done, in which case completed work is
      // never silently erased from the checklist.
      const doneButDeselected = prev.filter((s) => s.spareId && !selectedIds.has(s.spareId) && s.doneAt)
      const manual = prev.filter((s) => !s.spareId)
      return [...forSelected, ...doneButDeselected, ...manual]
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedSpares])

  if (technician.isLoading || settings.isLoading || jobDetail.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }
  if (jobDetail.isError || !ticket) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => jobDetail.refetch()} retryLabel={t("common.retry")} />
  }
  if (settings.isError || !settings.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => settings.refetch()} retryLabel={t("common.retry")} />
  }
  if (isTicketClosed(ticket.status) && !visitId) {
    return (
      <div className="pt-2">
        <Card className="items-center gap-2 py-8 text-center">
          <CheckCircle2 className="size-8 text-success" />
          <p className="text-sm font-medium text-text">{t("technician.onsite.jobClosedTitle")}</p>
          <p className="text-xs text-text-muted">{t("technician.onsite.jobClosedBody")}</p>
          <Button type="button" variant="outline" onClick={() => navigate(-1)}>
            {t("common.back")}
          </Button>
        </Card>
      </div>
    )
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

  // Vacuously true when empty — a job with nothing worth logging (no spares
  // used, no extra template steps picked) must not be stuck forever waiting
  // for an item that will never be added.
  const sopAllDone = sopSteps.every((s) => s.doneAt)
  const roValid = !isRo || roChecklistSchema.safeParse({
    tdsBefore: tdsBefore === "" ? undefined : Number(tdsBefore),
    tdsAfter: tdsAfter === "" ? undefined : Number(tdsAfter),
    tankCleaned,
    productExplained,
    clientName: roClientName,
  }).success

  // Purely visual "over expected time" flag. Compares live elapsed time
  // against the step's own `expectedMinutes` (the spare's standard_time or
  // the picked template's default_expected_minutes — see addSopStep below).
  // The "current" step is the first one not yet marked
  // done; its start is either the previous step's doneAt timestamp or, for
  // the first step, the visit's own timer_start — both already-recorded
  // technician data, nothing new is captured for this. `nowMs` derives from
  // the already-ticking `elapsedSec` (useVisitTimer) rather than a fresh
  // Date.now()/interval, so this recomputes on the same per-second tick the
  // header timer already uses.
  const currentSopStepIndex = sopSteps.findIndex((s) => !s.doneAt)
  const currentSopStep = currentSopStepIndex >= 0 ? sopSteps[currentSopStepIndex] : null
  const currentSopStepStartMs =
    currentSopStepIndex > 0 ? new Date(sopSteps[currentSopStepIndex - 1].doneAt!).getTime() : startedAt
  const nowMs = startedAt != null ? startedAt + elapsedSec * 1000 : Date.now()
  const currentSopStepElapsedMin = currentSopStepStartMs != null ? (nowMs - currentSopStepStartMs) / 60_000 : 0
  const isCurrentSopStepOverdue = !!currentSopStep && currentSopStepElapsedMin > currentSopStep.expectedMinutes

  function canAdvanceFrom(key: (typeof STEP_KEYS)[number]) {
    if (key === "sop") return !!beforeImage && sopAllDone
    if (key === "spares") return true
    if (key === "charges") return !isDiscountBlocked(discountPercent, adminMax)
    if (key === "ro") return roValid
    if (key === "afterphoto") return !!afterImage
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
    const template = sopStepTemplates.find((tpl) => tpl.id === selectedTemplateId)
    if (!template) return
    setSopSteps((prev) => [
      ...prev,
      { id: crypto.randomUUID(), name: template.name, expectedMinutes: template.default_expected_minutes, doneAt: null },
    ])
    setSelectedTemplateId("")
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
  // Task 6 — appends to the evidence array (damaged/replaced/installed
  // parts), full-array replace on every add/remove (see
  // queueVisitEvidencePhotos' doc comment in services/technician.ts).
  async function handleAddEvidencePhoto(dataUrl: string) {
    const next = [...evidenceImages, dataUrl]
    setEvidenceImages(next)
    if (visitId) await queueVisitEvidencePhotos.mutateAsync({ visitId, urls: next })
  }
  async function removeEvidencePhoto(index: number) {
    const next = evidenceImages.filter((_, i) => i !== index)
    setEvidenceImages(next)
    if (visitId) await queueVisitEvidencePhotos.mutateAsync({ visitId, urls: next })
  }

  /** Build Order A3 — cached/queued immediately (like signatures), not batched into handlePaymentSubmit's end-of-visit patch, so it survives the app closing mid-visit. `null` clears an already-recorded note. */
  async function handleVoiceNote(dataUrl: string | null) {
    setVoiceNoteUrl(dataUrl)
    if (visitId) await cacheVoiceNote.mutateAsync({ visitId, dataUrl })
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

  /**
   * GV.md §2 — the OTP entered here is verified server-side (verify_visit_otp)
   * in the SAME call that closes the visit (timer_end); there is no separate
   * "complete" step client-side any more, on purpose (see the migration's
   * design decision #2 — never trust a client-supplied code).
   */
  async function handlePaymentSubmit() {
    const result = servicePaymentSchema.safeParse({ method: paymentMethod, txnId, description: paymentDescription })
    if (!result.success) {
      setPaymentError(result.error.issues[0]?.message ?? "technician.errors.paymentInvalid")
      return
    }
    setPaymentError(null)

    const trimmedCode = otpCode.trim()
    if (!trimmedCode) {
      setOtpErrorKey("technician.onsite.otp.errors.required")
      return
    }
    if (!navigator.onLine) {
      setOtpErrorKey("technician.onsite.otp.errors.offline")
      return
    }
    if (!visitId || !profile) return

    setOtpErrorKey(null)
    setOtpRemaining(null)
    try {
      const outcome = await verifyOtp.mutateAsync({ orgId: profile.org_id, visitId, code: trimmedCode, notes: visitNotes })
      if (!outcome.ok) {
        setOtpRemaining(outcome.remaining_attempts)
        setOtpErrorKey("technician.onsite.otp.errors.incorrect")
        setOtpCode("")
        return
      }
      // The visit is done — its local draft has served its purpose and would
      // otherwise sit around as stale dead data (or, worse, confusingly
      // "resume" into a job this ticket can no longer be re-entered for).
      if (ticketId) await db.visitFormDrafts.delete(ticketId)
      navigate(`/technician/jobs/${ticketId}/rating`, { state: { visitId } })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      if (message.includes("otp_expired")) setOtpErrorKey("technician.onsite.otp.errors.expired")
      else if (message.includes("otp_locked")) setOtpErrorKey("technician.onsite.otp.errors.locked")
      else if (message.includes("otp_missing")) setOtpErrorKey("technician.onsite.otp.errors.missing")
      else toast.error(t("common.actionFailed"))
    }
  }

  /** Mints a brand-new code (resets expiry + attempts) — see generate_visit_otp's `p_force`. Used when the current code expired, locked out, or the customer never received it. */
  function handleResendOtp() {
    if (!visitId || !profile) return
    setOtpErrorKey(null)
    setOtpRemaining(null)
    setOtpCode("")
    setOtpGenerating(true)
    generateOtp.mutate(
      { orgId: profile.org_id, visitId, force: true },
      {
        onSuccess: () => toast.success(t("technician.onsite.otp.resent")),
        onSettled: () => setOtpGenerating(false),
        onError: () => toast.error(t("technician.onsite.otp.errors.generateFailed")),
      }
    )
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
    try {
      await generateEnquiry.mutateAsync({
        orgId: profile.org_id,
        customerId: ticket.customer_id,
        name: parsed.data.name,
        mobile: parsed.data.mobile || undefined,
        enquiryType: parsed.data.enquiryType,
        note: parsed.data.note || undefined,
        // GV.md 1.2: stamps leads.visit_id so this visit's enquiry-time
        // allowance condition is a real join, not a guess.
        visitId: visitId ?? undefined,
      })
      setEnquirySent(true)
    } catch {
      toast.error(t("common.actionFailed"))
    }
  }

  const minutes = String(Math.floor(elapsedSec / 60)).padStart(2, "0")
  const seconds = String(elapsedSec % 60).padStart(2, "0")

  return (
    <div className="space-y-4 pt-2 pb-8">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold text-text">{t("technician.onsite.title")}</h1>
        <span
          className={cn(
            "rounded-full px-3 py-1 font-mono text-sm font-semibold text-white",
            isCurrentSopStepOverdue ? "bg-danger" : "bg-ink"
          )}
        >
          {minutes}:{seconds}
        </span>
      </div>
      <p className="px-1 text-sm text-text-muted">{ticket.customers?.name} — {ticket.products?.name ?? ticket.name_of_complaint}</p>

      <div className="flex items-center justify-between gap-2 px-1">
        <p className="flex items-center gap-1.5 text-xs text-text-muted">
          <Save className="size-3.5" />
          {draftRestored ? t("technician.onsite.draft.restoredNote") : t("technician.onsite.draft.autosaveNote")}
        </p>
        {draftRestored ? (
          <button type="button" className="text-xs font-medium text-danger" onClick={() => setShowDiscardConfirm((v) => !v)}>
            {t("technician.onsite.draft.discard")}
          </button>
        ) : null}
      </div>
      {showDiscardConfirm ? (
        <Card className="gap-2 px-3.5 py-3">
          <p className="text-xs text-text-muted">{t("technician.onsite.draft.discardWarning")}</p>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => setShowDiscardConfirm(false)}>
              {t("common.cancel")}
            </Button>
            <Button type="button" variant="destructive" size="sm" onClick={() => void discardDraft()}>
              {t("technician.onsite.draft.confirmDiscard")}
            </Button>
          </div>
        </Card>
      ) : null}

      <Card>
        <Stepper steps={steps} currentIndex={step} maxCompletedIndex={maxStepReached} />
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
                {sopSteps.map((s, idx) => {
                  const isOverdue = idx === currentSopStepIndex && isCurrentSopStepOverdue
                  return (
                    <div
                      key={s.id}
                      className={cn(
                        "flex items-center gap-2.5 rounded-xl border px-3.5 py-2.5",
                        isOverdue ? "border-danger bg-danger/5" : "border-border"
                      )}
                    >
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
                        <p className={cn("text-xs", isOverdue ? "font-medium text-danger" : "text-text-muted")}>
                          {t("technician.onsite.sopExpected", { minutes: s.expectedMinutes })}
                        </p>
                        {isOverdue ? (
                          <p className="mt-0.5 flex items-center gap-1 text-xs text-danger">
                            <TriangleAlert className="size-3" /> {t("technician.onsite.sopOverdue")}
                          </p>
                        ) : null}
                      </div>
                      {!s.doneAt ? (
                        <Button type="button" variant="ghost" size="icon-sm" onClick={() => removeSopStep(s.id)}>
                          <Trash2 className="size-3.5 text-danger" />
                        </Button>
                      ) : null}
                    </div>
                  )
                })}
              </div>
            )}
            {sopStepTemplates.length > 0 ? (
              <div className="flex items-end gap-2 px-1">
                <div className="flex-1 space-y-1">
                  <Label htmlFor="stepTemplate">{t("technician.onsite.sopStepName")}</Label>
                  <select
                    id="stepTemplate"
                    value={selectedTemplateId}
                    onChange={(e) => setSelectedTemplateId(e.target.value)}
                    className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                  >
                    <option value="">{t("technician.onsite.sopStepPickPlaceholder")}</option>
                    {sopStepTemplates.map((tpl) => (
                      <option key={tpl.id} value={tpl.id}>
                        {tpl.name} ({t("technician.onsite.sopExpected", { minutes: tpl.default_expected_minutes })})
                      </option>
                    ))}
                  </select>
                </div>
                <Button type="button" variant="outline" size="icon" onClick={addSopStep} disabled={!selectedTemplateId}>
                  <Plus className="size-4" />
                </Button>
              </div>
            ) : null}
          </Card>
        </div>
      ) : null}

      {currentKey === "spares" ? (
        <SpareSelectStep orgId={profile?.org_id} productId={ticket.product_id} selected={selectedSpares} onChange={setSelectedSpares} />
      ) : null}

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

      {currentKey === "afterphoto" ? (
        <div className="space-y-4">
          <p className="px-1 text-sm text-text-muted">{t("technician.onsite.afterImageHint")}</p>
          <PhotoCapture label={t("technician.onsite.afterImage")} dataUrl={afterImage} onCaptured={handleAfterImage} />

          {/* Task 6 — additional evidence: damaged/replaced/installed parts,
              beyond the single before/after image. */}
          <Card className="gap-2">
            <p className="px-1 text-sm font-medium text-text">{t("technician.onsite.evidence.title")}</p>
            <p className="px-1 text-xs text-text-muted">{t("technician.onsite.evidence.hint")}</p>
            {evidenceImages.length > 0 ? (
              <div className="grid grid-cols-3 gap-2 px-1">
                {evidenceImages.map((url, idx) => (
                  <div key={idx} className="relative">
                    <img src={url} alt="" className="aspect-square w-full rounded-lg border border-border object-cover" />
                    <button
                      type="button"
                      onClick={() => void removeEvidencePhoto(idx)}
                      className="absolute top-1 right-1 flex size-5 items-center justify-center rounded-full bg-danger text-white"
                    >
                      <Trash2 className="size-3" />
                    </button>
                  </div>
                ))}
              </div>
            ) : null}
            <PhotoCapture label={t("technician.onsite.evidence.addLabel")} dataUrl={null} onCaptured={handleAddEvidencePhoto} />
          </Card>

          <Card className="gap-2">
            <div className="space-y-1 px-1">
              <Label htmlFor="visitNotes">{t("technician.onsite.visitNotes.label")}</Label>
              <p className="text-xs text-text-muted">{t("technician.onsite.visitNotes.hint")}</p>
            </div>
            <textarea
              id="visitNotes"
              value={visitNotes}
              onChange={(e) => setVisitNotes(e.target.value)}
              placeholder={t("technician.onsite.visitNotes.placeholder")}
              rows={4}
              className={textareaClass}
            />
          </Card>

          <Card className="gap-2">
            <div className="space-y-1 px-1">
              <p className="text-xs text-text-muted">{t("technician.voiceNote.hint")}</p>
            </div>
            <VoiceNoteRecorder label={t("technician.voiceNote.label")} dataUrl={voiceNoteUrl} onChange={handleVoiceNote} />
          </Card>
        </div>
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

          <div className="space-y-2 rounded-xl border border-border bg-surface-alt/40 px-3.5 py-3">
            <p className="text-sm font-semibold text-text">{t("technician.onsite.otp.title")}</p>
            <p className="text-xs text-text-muted">{t("technician.onsite.otp.hint")}</p>
            <div className="flex items-end gap-2">
              <div className="flex-1 space-y-1">
                <Label htmlFor="otpCode">{t("technician.onsite.otp.codeLabel")}</Label>
                <Input
                  id="otpCode"
                  inputMode="numeric"
                  maxLength={4}
                  value={otpCode}
                  onChange={(e) => setOtpCode(e.target.value.replace(/\D/g, "").slice(0, 4))}
                  placeholder="••••"
                  className="text-center text-lg tracking-[0.5em]"
                />
              </div>
              <Button type="button" variant="outline" size="sm" onClick={handleResendOtp} disabled={otpGenerating || !visitId}>
                {otpGenerating ? <Loader2 className="size-3.5 animate-spin" /> : t("technician.onsite.otp.resendButton")}
              </Button>
            </div>
            {otpErrorKey ? (
              <p className="text-xs text-danger">
                {t(otpErrorKey, { remaining: otpRemaining ?? 0 })}
              </p>
            ) : null}
          </div>

          <Button type="button" onClick={handlePaymentSubmit} disabled={verifyOtp.isPending}>
            {verifyOtp.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.onsite.payment.complete")}
          </Button>
        </Card>
      ) : null}

      {isRo ? (
        <SellAmcSection orgId={profile?.org_id} customerId={ticket.customer_id} productId={ticket.product_id!} productName={ticket.products?.name ?? ""} />
      ) : null}

      <Card className="gap-2.5">
        <button type="button" className="px-1 text-left text-sm font-semibold text-accent" onClick={() => setShowEnquiry((v) => !v)}>
          {t("technician.onsite.enquiry.toggle")}
        </button>
        {showEnquiry ? <p className="px-1 text-xs text-text-muted">{t("technician.onsite.enquiry.hint")}</p> : null}
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
          <Button
            type="button"
            disabled={!canAdvanceFrom(currentKey)}
            onClick={() => {
              const next = step + 1
              setStep(next)
              setMaxStepReached((m) => Math.max(m, next))
            }}
          >
            {t("technician.onsite.next")}
          </Button>
        ) : null}
      </div>
    </div>
  )
}
