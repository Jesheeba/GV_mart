import { useEffect, useMemo, useState, type ReactNode } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { useQuery } from "@tanstack/react-query"
import { CalendarClock, KeyRound, Loader2, Pencil, PhoneCall, ShieldOff, Trash2, TriangleAlert, UserCog, XCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { SegButton } from "@/components/shared/SegButton"
import { NotInInventoryProductDialog } from "@/components/shared/NotInInventoryProductDialog"
import { useToast } from "@/components/ui/toast-context"
import { useCustomerExemptionWindows } from "@/hooks/useCustomers"
import { useProfile } from "@/hooks/useProfile"
import { brandsHooks, modelsHooks, productsHooks, useSettings } from "@/hooks/useMasters"
import {
  useAdminOverrideVisitCompletion,
  useAssignTicketTechnician,
  useAutoAssignTicket,
  useCancelServiceTicket,
  useCustomerAddresses,
  useDeleteServiceTicket,
  useLogConfirmedAvailability,
  useOwnedEquipment,
  usePaymentProofs,
  useTechnicians,
  useTicket,
  useTicketEvidence,
  useTicketPhotos,
  useUpdateTicketAddress,
  useUpdateTicketEstimatedDuration,
  useUpdateTicketProduct,
} from "@/hooks/useService"
import type { ConfirmedAvailabilityReason } from "@/services/service"
import { ticketPhotoSignedUrl } from "@/services/ticketPhotos"
import { paymentProofSignedUrl } from "@/services/paymentProofs"
import { computeJobOverrun } from "@/lib/job-overrun"
import { computeAllowedDurationMinutes, sumItemStandardMinutes } from "@/lib/job-allowance"
import { resolveVisitDurationMinutes } from "@/lib/visit-duration"
import { cn } from "@/lib/utils"
import { ChannelBadge, PriorityBadge, TicketTypeBadge } from "./TicketBadges"
import { SlaCountdown } from "./SlaCountdown"

function TicketPhotoThumb({ storagePath }: { storagePath: string }) {
  const { data: url } = useQuery({
    queryKey: ["ticketPhotoUrl", storagePath],
    queryFn: () => ticketPhotoSignedUrl(storagePath),
    staleTime: 30 * 60_000,
  })
  if (!url) return <div className="size-16 shrink-0 animate-pulse rounded-lg bg-surface-alt" />
  return <img src={url} alt="" className="size-16 shrink-0 rounded-lg object-cover" />
}

// Enhancement spec Task 2 — one uploaded UPI payment proof, with the
// screenshot/photo plus the audit-trail fields the spec calls out (payment
// date/time, method, transaction reference, technician name).
function PaymentProofCard({
  proof,
}: {
  proof: {
    id: string
    storage_path: string
    transaction_reference: string | null
    technicians: { profiles: { full_name: string } | null } | null
    payments: { payment_method: string; paid_at: string } | null
  }
}) {
  const { t } = useTranslation()
  const { data: url } = useQuery({
    queryKey: ["paymentProofUrl", proof.storage_path],
    queryFn: () => paymentProofSignedUrl(proof.storage_path),
    staleTime: 30 * 60_000,
  })
  const paidAt = proof.payments?.paid_at ? new Date(proof.payments.paid_at) : null
  return (
    <div className="flex gap-3 rounded-xl border border-border p-2.5">
      {url ? (
        <a href={url} target="_blank" rel="noreferrer">
          <img src={url} alt="" className="size-20 shrink-0 rounded-lg object-cover" />
        </a>
      ) : (
        <div className="size-20 shrink-0 animate-pulse rounded-lg bg-surface-alt" />
      )}
      <div className="min-w-0 space-y-0.5 text-xs">
        <p className="text-text-muted">
          {t("service.detail.paymentProof.date")}: <span className="text-text">{paidAt ? paidAt.toLocaleDateString() : "—"}</span>
        </p>
        <p className="text-text-muted">
          {t("service.detail.paymentProof.time")}: <span className="text-text">{paidAt ? paidAt.toLocaleTimeString() : "—"}</span>
        </p>
        <p className="text-text-muted">
          {t("service.detail.paymentProof.method")}: <span className="text-text">{proof.payments?.payment_method ?? "—"}</span>
        </p>
        <p className="text-text-muted">
          {t("service.detail.paymentProof.txnRef")}: <span className="text-text">{proof.transaction_reference ?? "—"}</span>
        </p>
        <p className="text-text-muted">
          {t("service.detail.paymentProof.technician")}: <span className="text-text">{proof.technicians?.profiles?.full_name ?? "—"}</span>
        </p>
      </div>
    </div>
  )
}

const textareaClass =
  "w-full min-w-0 rounded-xl border border-input bg-surface px-3.5 py-2.5 text-sm text-text transition-colors outline-none placeholder:text-text-muted focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"

export function TicketDetailPage() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { id } = useParams<{ id: string }>()
  const { data: profile } = useProfile()
  const { data: ticket, isLoading, isError, refetch } = useTicket(id)
  const { data: evidence, isLoading: evidenceLoading, isError: evidenceError, refetch: refetchEvidence } = useTicketEvidence(id)
  const { data: technicians } = useTechnicians(ticket?.org_id)
  // GV.md 1.2 — allowed-time inputs (review/enquiry allowance minutes).
  const { data: settings } = useSettings(ticket?.org_id)
  // B4: shown red here as the "technician/scheduling view" the spec calls
  // out — no assignment should happen inside these windows.
  const exemptionWindows = useCustomerExemptionWindows(ticket?.customer_id)
  const autoAssign = useAutoAssignTicket()
  const assign = useAssignTicketTechnician()
  const [pickerTechId, setPickerTechId] = useState("")

  // Task 5 (2026-07-30/31) — exception path on top of unchanged
  // auto-assignment: log a phone-confirmed availability window (customer
  // follow-up/complaint, or the assigned technician can't make the day).
  const [loggingAvailability, setLoggingAvailability] = useState(false)
  const [availReason, setAvailReason] = useState<ConfirmedAvailabilityReason>("customer_followup")
  const [availDate, setAvailDate] = useState("")
  const [availFrom, setAvailFrom] = useState("")
  const [availTo, setAvailTo] = useState("")
  const [availNote, setAvailNote] = useState("")
  const logAvailability = useLogConfirmedAvailability()

  const [editingAddress, setEditingAddress] = useState(false)
  const [addressPickerId, setAddressPickerId] = useState("")
  const addresses = useCustomerAddresses(editingAddress ? ticket?.customer_id : undefined)
  const updateAddress = useUpdateTicketAddress()

  // Gate-assignment-on-product (2026-08-04) — same editingAddress pattern,
  // but with three source modes (owned / catalog / not-in-inventory free
  // text) instead of a single dropdown. See NewComplaintPage.tsx's
  // equipment step for the sibling implementation.
  const [editingProduct, setEditingProduct] = useState(false)
  const [productMode, setProductMode] = useState<"owned" | "catalog">("owned")
  const [productOwnedId, setProductOwnedId] = useState("")
  const [productBrandId, setProductBrandId] = useState("")
  const [productModelId, setProductModelId] = useState("")
  const [productCatalogId, setProductCatalogId] = useState("")
  const [notInInventoryDialogOpen, setNotInInventoryDialogOpen] = useState(false)
  const updateProduct = useUpdateTicketProduct()
  const owned = useOwnedEquipment(ticket?.org_id, ticket?.customer_id)
  const { data: brands } = brandsHooks.useList(ticket?.org_id)
  const { data: models } = modelsHooks.useList(ticket?.org_id)
  const { data: products } = productsHooks.useList(ticket?.org_id)
  const filteredModels = useMemo(() => (models ?? []).filter((m) => !productBrandId || m.brand_id === productBrandId), [models, productBrandId])
  const filteredProducts = useMemo(
    () => (products ?? []).filter((p) => (!productBrandId || p.brand_id === productBrandId) && (!productModelId || p.model_id === productModelId)),
    [products, productBrandId, productModelId]
  )
  const photos = useTicketPhotos(ticket?.id)
  const paymentProofs = usePaymentProofs(ticket?.invoice_id ?? undefined)
  // Auto-expand the editor the moment a product-less ticket loads — this is
  // not an optional edit like address, the assignment gate requires it.
  useEffect(() => {
    if (ticket && !ticket.product_id && !ticket.unlisted_product_name) {
      setEditingProduct(true)
      setProductMode("owned")
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ticket?.id])

  const [cancelling, setCancelling] = useState(false)
  const [cancelReason, setCancelReason] = useState("")
  const cancelTicket = useCancelServiceTicket()
  const deleteTicket = useDeleteServiceTicket()

  // GV.md §2 — the one sanctioned OTP escape hatch. See design decision #5
  // in 20260725110000_otp_completion_confirmation.sql for why this exists
  // and stays deliberately minimal (no signature/photo fallback tiers).
  const [overridingOtp, setOverridingOtp] = useState(false)
  const [otpOverrideReason, setOtpOverrideReason] = useState("")
  const overrideVisitCompletion = useAdminOverrideVisitCompletion()

  // Build Order A4: admin-set estimate override the overrun check compares
  // elapsed visit time against (see src/lib/job-overrun.ts). The Phase 1
  // trigger (_service_tickets_derive_skill_and_duration) already
  // auto-populates this by ticket type for most tickets — this field is a
  // per-ticket override, not the primary source.
  const [editingEstimate, setEditingEstimate] = useState(false)
  const [estimateDraft, setEstimateDraft] = useState("")
  const updateEstimate = useUpdateTicketEstimatedDuration()
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const tickId = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(tickId)
  }, [])

  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (isError || !ticket) {
    return <FullPageError message={t("service.error.loadFailed")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const appointment = ticket.appointments[0]
  const productDefined = !!ticket.product_id || !!ticket.unlisted_product_name
  const visit = ticket.service_visits?.[0]
  const openVisit = ticket.service_visits?.find((v) => v.timer_start && !v.timer_end) ?? null
  const totalMinutes = resolveVisitDurationMinutes(visit)
  const lateSopSteps = visit?.service_sop_steps?.filter((s) => (s.overdue_minutes ?? 0) > 0)
  const canManage = profile?.role === "master" || profile?.role === "operation_admin"
  const canCancelOrDelete = canManage && ticket.status !== "completed" && ticket.status !== "cancelled"
  // GV.md 1.2: same allowed-time formula as the technician screens (see
  // src/lib/job-allowance.ts) — base estimate from the open visit's actual
  // items' standard times (falling back to the ticket's type default),
  // plus the review/enquiry allowances when this visit actually earned them.
  const openVisitFull = ticket.service_visits?.find((v: { timer_start: string | null; timer_end: string | null }) => v.timer_start && !v.timer_end) as
    | { service_spares_used?: { qty: number; spares: { standard_time_minutes: number | null } | null }[]; ratings?: { google_review_clicked: boolean } | null; leads?: { id: string }[] }
    | undefined
  const allowedDuration = computeAllowedDurationMinutes({
    itemsStandardMinutesSum: sumItemStandardMinutes(
      (openVisitFull?.service_spares_used ?? []).map((s) => ({ qty: s.qty, standardTimeMinutes: s.spares?.standard_time_minutes }))
    ),
    ticketEstimatedDurationMinutes: ticket.estimated_duration_minutes,
    reviewAllowanceMinutes: settings?.review_time_allowance_minutes ?? 0,
    enquiryAllowanceMinutes: settings?.enquiry_time_allowance_minutes ?? 0,
    reviewCollected: openVisitFull?.ratings?.google_review_clicked ?? false,
    enquiryLoggedThisVisit: (openVisitFull?.leads?.length ?? 0) > 0,
  })
  const overrun = computeJobOverrun(
    { timerStart: openVisit?.timer_start, timerEnd: openVisit?.timer_end, estimatedDurationMinutes: allowedDuration },
    now
  )

  function startEditingEstimate() {
    setEstimateDraft(ticket!.estimated_duration_minutes != null ? String(ticket!.estimated_duration_minutes) : "")
    setEditingEstimate(true)
  }
  function saveEstimate() {
    const trimmed = estimateDraft.trim()
    const minutes = trimmed === "" ? null : Number(trimmed)
    if (minutes != null && (!Number.isFinite(minutes) || minutes <= 0)) {
      toast.error(t("service.detail.estimateInvalid"))
      return
    }
    updateEstimate.mutate(
      { ticketId: ticket!.id, minutes },
      { onSuccess: () => setEditingEstimate(false), onError: () => toast.error(t("common.actionFailed")) }
    )
  }

  function startEditingAddress() {
    setAddressPickerId(ticket!.address_id ?? "")
    setEditingAddress(true)
  }
  function saveAddress() {
    updateAddress.mutate(
      { ticketId: ticket!.id, addressId: addressPickerId || null },
      { onSuccess: () => setEditingAddress(false), onError: () => toast.error(t("common.actionFailed")) }
    )
  }

  function startEditingProduct() {
    setProductMode(ticket!.product_id ? "catalog" : "owned")
    setProductOwnedId(ticket!.product_id ?? "")
    setProductBrandId(ticket!.brand_id ?? "")
    setProductModelId(ticket!.model_id ?? "")
    setProductCatalogId(ticket!.product_id ?? "")
    setEditingProduct(true)
  }
  function saveProduct() {
    const resolvedId = productMode === "owned" ? productOwnedId : productCatalogId
    const ownedMatch = (owned.data ?? []).find((o) => o.productId === resolvedId)
    const brandId = productMode === "owned" ? (ownedMatch?.brandId ?? null) : productBrandId || null
    const modelId = productMode === "owned" ? (ownedMatch?.modelId ?? null) : productModelId || null
    updateProduct.mutate(
      { ticketId: ticket!.id, productId: resolvedId || null, brandId, modelId, unlistedProductName: null },
      {
        onSuccess: () => setEditingProduct(false),
        onError: (err) => {
          // The toast alone can't distinguish a real failure from a dropped
          // request — this was silently swallowed before, leaving admins
          // stuck re-picking the same product with no diagnostic trail.
          console.error("Failed to save ticket product:", err)
          toast.error(t("common.actionFailed"))
        },
      }
    )
  }
  function saveNotInInventoryProduct(name: string) {
    updateProduct.mutate(
      { ticketId: ticket!.id, productId: null, brandId: null, modelId: null, unlistedProductName: name },
      {
        onSuccess: () => {
          setEditingProduct(false)
          setNotInInventoryDialogOpen(false)
        },
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  function confirmCancel() {
    if (!ticket || !cancelReason.trim()) return
    cancelTicket.mutate(
      { ticketId: ticket.id, reason: cancelReason.trim() },
      {
        onSuccess: () => {
          setCancelling(false)
          setCancelReason("")
          toast.success(t("service.detail.cancelSuccess"))
        },
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  function confirmOverrideOtp() {
    if (!openVisit || !ticket || !otpOverrideReason.trim()) return
    overrideVisitCompletion.mutate(
      { orgId: ticket.org_id, visitId: openVisit.id, reason: otpOverrideReason.trim() },
      {
        onSuccess: () => {
          setOverridingOtp(false)
          setOtpOverrideReason("")
          toast.success(t("service.detail.overrideSuccess"))
          refetch()
        },
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  function handleDelete() {
    if (!ticket) return
    if (!window.confirm(t("service.detail.deleteConfirm"))) return
    deleteTicket.mutate(ticket.id, {
      onSuccess: () => {
        toast.success(t("service.detail.deleteSuccess"))
        navigate("/admin/service")
      },
      onError: (err) => {
        const message = typeof err === "object" && err && "message" in err ? String((err as { message: unknown }).message) : ""
        toast.error(message.includes("cannot be hard-deleted") ? t("service.detail.deleteBlocked") : t("common.actionFailed"))
      },
    })
  }

  return (
    <div className="mx-auto max-w-3xl space-y-4 pt-2">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-text">#{ticket.id.slice(0, 8)}</h1>
          <p className="text-sm text-text-muted">{ticket.customers?.name} · {ticket.customers?.mobile}</p>
        </div>
        <div className="flex items-center gap-2">
          {canCancelOrDelete ? (
            <>
              <Button
                variant="outline"
                size="sm"
                onClick={() => setCancelling((v) => !v)}
                disabled={cancelTicket.isPending}
              >
                <XCircle className="size-3.5" />
                {t("service.detail.cancelTicket")}
              </Button>
              <Button
                variant="destructive"
                size="sm"
                onClick={handleDelete}
                disabled={deleteTicket.isPending}
                title={ticket.invoice_id ? t("service.detail.deleteBlocked") : undefined}
              >
                {deleteTicket.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Trash2 className="size-3.5" />}
                {t("common.delete")}
              </Button>
            </>
          ) : null}
          <Button variant="outline" onClick={() => navigate("/admin/service")}>
            {t("customers.form.back")}
          </Button>
        </div>
      </div>

      {cancelling ? (
        <Card className="gap-3 px-5">
          <h2 className="text-sm font-semibold text-text">{t("service.detail.cancelTicket")}</h2>
          <div className="space-y-1.5">
            <label htmlFor="cancel-reason" className="block text-xs font-medium text-text-muted">
              {t("service.detail.cancelReasonLabel")}
            </label>
            <textarea
              id="cancel-reason"
              rows={3}
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              placeholder={t("service.detail.cancelReasonPlaceholder")}
              className={textareaClass}
            />
          </div>
          <div className="flex gap-2">
            <Button size="sm" variant="destructive" disabled={!cancelReason.trim() || cancelTicket.isPending} onClick={confirmCancel}>
              {cancelTicket.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("service.detail.confirmCancel")}
            </Button>
            <Button size="sm" variant="ghost" onClick={() => { setCancelling(false); setCancelReason("") }}>
              {t("common.cancel")}
            </Button>
          </div>
        </Card>
      ) : null}

      {ticket.status === "cancelled" && ticket.cancellation_reason ? (
        <Card className="gap-1.5 px-5">
          <h2 className="text-sm font-semibold text-text">{t("service.detail.cancellationReason")}</h2>
          <p className="text-sm text-text-muted">{ticket.cancellation_reason}</p>
        </Card>
      ) : null}

      <Card className="gap-3 px-5">
        <div className="flex flex-wrap items-center gap-2">
          <TicketTypeBadge type={ticket.type} />
          <PriorityBadge priority={ticket.priority} />
          <ChannelBadge channel={ticket.channel} />
          <SlaCountdown slaDueAt={ticket.sla_due_at} status={ticket.status} />
          {appointment?.is_narrow_window ? (
            <span className="flex items-center gap-1 rounded-full bg-warning/15 px-2.5 py-1 text-xs font-medium text-warning">
              <CalendarClock className="size-3" />
              {t("service.detail.narrowWindowBadge")}
            </span>
          ) : null}
          {appointment?.next_day_priority ? (
            <span className="flex items-center gap-1 rounded-full bg-warning/15 px-2.5 py-1 text-xs font-medium text-warning">
              {t("service.detail.nextDayPriorityBadge")}
              {appointment.rescheduled_from_date ? ` (${t("service.detail.rescheduledFrom", { date: new Date(appointment.rescheduled_from_date).toLocaleDateString() })})` : ""}
            </span>
          ) : null}
          {ticket.invoice_id ? (
            <span className="text-xs text-text-muted">{t("service.detail.createdFromInvoice", { id: ticket.invoice_id.slice(0, 8) })}</span>
          ) : null}
        </div>
        <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
          <div>
            <div className="flex items-center gap-1.5 text-xs text-text-muted">
              {t("service.table.product")}
              {!editingProduct ? (
                <button type="button" onClick={startEditingProduct} className="text-accent" title={t("service.detail.productEditor.editButton")}>
                  <Pencil className="size-3" />
                </button>
              ) : null}
            </div>
            <div className="text-text">
              {[ticket.products?.name, ticket.brands?.name, ticket.models?.name].filter(Boolean).join(" · ") || ticket.unlisted_product_name || "—"}
            </div>
          </div>
          <Field label={t("service.newComplaint.nameOfComplaint")} value={ticket.name_of_complaint || "—"} />
          <Field label={t("service.newComplaint.natureOfComplaint")} value={ticket.nature_of_complaint || "—"} />
          <Field label={t("service.table.appointment")} value={appointment?.mode === "always" ? t("service.appointment.always") : appointment?.scheduled_at ? new Date(appointment.scheduled_at).toLocaleString() : "—"} />
          <Field label={t("service.detail.status")} value={t(`service.status.${ticket.status}`)} />
          {!editingAddress ? (
            <div>
              <div className="flex items-center gap-1.5 text-xs text-text-muted">
                {t("service.table.area")}
                <button type="button" onClick={startEditingAddress} className="text-accent" title={t("service.detail.editAddress")}>
                  <Pencil className="size-3" />
                </button>
              </div>
              <div className="text-text">{ticket.addresses?.area ?? "—"}</div>
            </div>
          ) : (
            <div className="space-y-1.5">
              <div className="text-xs text-text-muted">{t("service.table.area")}</div>
              <select
                value={addressPickerId}
                onChange={(e) => setAddressPickerId(e.target.value)}
                className="h-8 w-full rounded-xl border border-border bg-surface px-2.5 text-sm text-text outline-none"
              >
                <option value="">{t("service.newComplaint.addressNone")}</option>
                {(addresses.data ?? []).map((a) => (
                  <option key={a.id} value={a.id}>
                    {[a.door_no, a.area].filter(Boolean).join(", ") || a.id.slice(0, 8)}
                    {a.is_primary ? ` (${t("customers.detail.primary")})` : ""}
                  </option>
                ))}
              </select>
              <div className="flex gap-2">
                <Button size="xs" disabled={updateAddress.isPending} onClick={saveAddress}>
                  {updateAddress.isPending ? <Loader2 className="size-3 animate-spin" /> : t("common.save")}
                </Button>
                <Button size="xs" variant="ghost" onClick={() => setEditingAddress(false)}>
                  {t("common.cancel")}
                </Button>
              </div>
            </div>
          )}
        </div>

        {editingProduct ? (
          <div className="space-y-3 border-t border-border pt-3">
            {!ticket.product_id && !ticket.unlisted_product_name ? (
              <div className="flex items-start gap-2 rounded-xl bg-warning/10 px-3 py-2.5 text-sm text-warning">
                <TriangleAlert className="mt-0.5 size-4 shrink-0" />
                <div>
                  <p className="font-medium">{t("service.detail.productEditor.missingTitle")}</p>
                  <p className="text-xs">{t("service.detail.productEditor.missingHint")}</p>
                </div>
              </div>
            ) : null}

            <div className="flex gap-1 rounded-full bg-surface-alt p-1">
              {(["owned", "catalog", "notInInventory"] as const).map((m) => (
                <SegButton
                  key={m}
                  active={m !== "notInInventory" && productMode === m}
                  onClick={() => (m === "notInInventory" ? setNotInInventoryDialogOpen(true) : setProductMode(m))}
                  className="flex-1 py-1.5 text-xs font-medium"
                >
                  {t(`service.detail.productEditor.mode.${m}`)}
                </SegButton>
              ))}
            </div>

            {productMode === "owned" ? (
              (owned.data ?? []).length === 0 ? (
                <p className="text-sm text-text-muted">{t("service.newComplaint.noOwnedEquipment")}</p>
              ) : (
                <div className="space-y-2">
                  {(owned.data ?? []).map((o) => (
                    <button
                      key={o.productId}
                      type="button"
                      onClick={() => setProductOwnedId(o.productId)}
                      className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                        productOwnedId === o.productId ? "border-accent bg-accent-soft" : "border-border"
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
                    value={productBrandId}
                    onChange={(e) => {
                      setProductBrandId(e.target.value)
                      setProductModelId("")
                      setProductCatalogId("")
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
                    value={productModelId}
                    onChange={(e) => {
                      setProductModelId(e.target.value)
                      setProductCatalogId("")
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
                    value={productCatalogId}
                    onChange={(e) => setProductCatalogId(e.target.value)}
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

            <div className="flex gap-2">
              <Button
                size="xs"
                disabled={updateProduct.isPending || (productMode === "owned" ? !productOwnedId : !productCatalogId)}
                onClick={saveProduct}
              >
                {updateProduct.isPending ? <Loader2 className="size-3 animate-spin" /> : t("service.detail.productEditor.save")}
              </Button>
              {ticket.product_id || ticket.unlisted_product_name ? (
                <Button size="xs" variant="ghost" onClick={() => setEditingProduct(false)}>
                  {t("service.detail.productEditor.cancel")}
                </Button>
              ) : null}
            </div>
          </div>
        ) : null}

        <NotInInventoryProductDialog
          open={notInInventoryDialogOpen}
          initialValue={ticket.unlisted_product_name ?? ""}
          onOpenChange={setNotInInventoryDialogOpen}
          onSave={saveNotInInventoryProduct}
        />

        {(photos.data ?? []).length > 0 ? (
          <div className="space-y-1.5 border-t border-border pt-3">
            <p className="text-xs text-text-muted">{t("service.detail.attachedPhotos")}</p>
            <div className="flex flex-wrap gap-2">
              {photos.data!.map((p) => (
                <TicketPhotoThumb key={p.id} storagePath={p.storage_path} />
              ))}
            </div>
          </div>
        ) : null}

        {(appointment?.appointment_unavailable_windows?.length ?? 0) > 0 || (exemptionWindows.data?.length ?? 0) > 0 ? (
          <div className="flex flex-wrap items-center gap-1.5 border-t border-border pt-3">
            <ShieldOff className="size-3.5 text-danger" />
            {(appointment?.appointment_unavailable_windows ?? []).map((w) => (
              <span key={w.id} className="rounded-full border border-danger/30 bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
                {w.start_time.slice(0, 5)}–{w.end_time.slice(0, 5)}
              </span>
            ))}
            {(exemptionWindows.data ?? []).filter((w) => w.is_active).map((w) => (
              <span key={w.id} className="rounded-full border border-danger/30 bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
                {w.label} · {w.start_time.slice(0, 5)}–{w.end_time.slice(0, 5)}
              </span>
            ))}
          </div>
        ) : null}
      </Card>

      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("service.detail.assignment")}</h2>
        {appointment?.technician_id ? (
          <p className="text-sm text-text">
            {t("service.detail.assignedTo", { name: appointment.technicians?.profiles?.full_name ?? "—" })}
          </p>
        ) : appointment ? (
          <div className="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              onClick={() => autoAssign.mutate(ticket.id, { onError: () => toast.error(t("common.actionFailed")) })}
              disabled={autoAssign.isPending || !productDefined}
            >
              {autoAssign.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <UserCog className="size-3.5" />}
              {t("service.detail.autoAssign")}
            </Button>
            <select
              value={pickerTechId}
              onChange={(e) => setPickerTechId(e.target.value)}
              disabled={!productDefined}
              className="h-8 rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none disabled:opacity-50"
            >
              <option value="">{t("service.detail.pickTechnician")}</option>
              {(technicians ?? []).map((tc) => (
                <option key={tc.id} value={tc.id}>
                  {tc.full_name} {tc.is_on_duty ? "" : `(${t("service.detail.offDuty")})`}
                </option>
              ))}
            </select>
            <Button
              size="sm"
              variant="outline"
              disabled={!pickerTechId || assign.isPending || !productDefined}
              onClick={() =>
                appointment &&
                assign.mutate(
                  { appointmentId: appointment.id, technicianId: pickerTechId },
                  { onError: () => toast.error(t("common.actionFailed")) }
                )
              }
            >
              {t("service.detail.assignManually")}
            </Button>
          </div>
        ) : (
          <p className="text-sm text-text-muted">{t("service.detail.noAppointment")}</p>
        )}
        {appointment && !appointment.technician_id && !productDefined ? (
          <p className="text-xs text-warning">{t("service.assign.productRequired")}</p>
        ) : null}
        {autoAssign.data && !autoAssign.data.assigned ? (
          <p className="text-xs text-warning">{t(autoAssign.data.reason_key ?? "service.assign.noneAvailable")}</p>
        ) : null}
        {assign.data && !assign.data.assigned ? <p className="text-xs text-warning">{t(assign.data.reason_key ?? "service.assign.technicianBusy")}</p> : null}
      </Card>

      {appointment ? (
        <Card className="gap-3 px-5">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold text-text">{t("service.detail.confirmedAvailability.title")}</h2>
            {!loggingAvailability ? (
              <Button size="sm" variant="outline" onClick={() => setLoggingAvailability(true)}>
                <PhoneCall className="size-3.5" />
                {t("service.detail.confirmedAvailability.logButton")}
              </Button>
            ) : null}
          </div>

          {(appointment.appointment_availability_calls ?? []).length > 0 ? (
            <ul className="space-y-1.5">
              {[...(appointment.appointment_availability_calls ?? [])]
                .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
                .map((c) => (
                  <li key={c.id} className="rounded-xl border border-border px-3 py-2 text-xs">
                    <p className="font-medium text-text">
                      {new Date(c.confirmed_date).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}{" "}
                      {c.confirmed_from.slice(0, 5)}–{c.confirmed_to.slice(0, 5)}
                      <span className="ml-1.5 font-normal text-text-muted">
                        · {t(`service.detail.confirmedAvailability.reason.${c.reason}`)}
                      </span>
                    </p>
                    <p className="mt-0.5 text-text-muted">
                      {t("service.detail.confirmedAvailability.loggedBy", {
                        name: c.profiles?.full_name ?? "—",
                        date: new Date(c.created_at).toLocaleDateString("en-IN", { day: "2-digit", month: "short" }),
                      })}
                    </p>
                    {c.note ? <p className="mt-0.5 text-text">{c.note}</p> : null}
                  </li>
                ))}
            </ul>
          ) : !loggingAvailability ? (
            <p className="text-xs text-text-muted">{t("service.detail.confirmedAvailability.empty")}</p>
          ) : null}

          {loggingAvailability ? (
            <div className="space-y-2.5 border-t border-border pt-3">
              <div className="flex gap-1 rounded-full bg-surface-alt p-1">
                {(["customer_followup", "technician_unavailable"] as const).map((r) => (
                  <button
                    key={r}
                    type="button"
                    onClick={() => setAvailReason(r)}
                    className={cn(
                      "flex-1 rounded-full px-3 py-1.5 text-xs font-medium transition-colors",
                      availReason === r ? "bg-ink text-white" : "text-text-muted"
                    )}
                  >
                    {t(`service.detail.confirmedAvailability.reason.${r}`)}
                  </button>
                ))}
              </div>
              <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-3">
                <div className="space-y-1">
                  <Label htmlFor="avail-call-date">{t("service.detail.confirmedAvailability.date")}</Label>
                  <DatePicker id="avail-call-date" value={availDate} onChange={setAvailDate} />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="avail-call-from">{t("service.detail.confirmedAvailability.from")}</Label>
                  <Input id="avail-call-from" type="time" value={availFrom} onChange={(e) => setAvailFrom(e.target.value)} />
                </div>
                <div className="space-y-1">
                  <Label htmlFor="avail-call-to">{t("service.detail.confirmedAvailability.to")}</Label>
                  <Input id="avail-call-to" type="time" value={availTo} onChange={(e) => setAvailTo(e.target.value)} />
                </div>
              </div>
              <div className="space-y-1">
                <Label htmlFor="avail-call-note">{t("service.detail.confirmedAvailability.note")}</Label>
                <textarea
                  id="avail-call-note"
                  rows={2}
                  value={availNote}
                  onChange={(e) => setAvailNote(e.target.value)}
                  placeholder={t("service.detail.confirmedAvailability.notePlaceholder")}
                  className={textareaClass}
                />
              </div>
              {availFrom && availTo && availFrom >= availTo ? (
                <p className="text-xs text-danger">{t("service.detail.confirmedAvailability.rangeInvalid")}</p>
              ) : null}
              <div className="flex gap-2">
                <Button
                  size="sm"
                  disabled={!availDate || !availFrom || !availTo || availFrom >= availTo || logAvailability.isPending}
                  onClick={() =>
                    logAvailability.mutate(
                      { appointmentId: appointment.id, reason: availReason, confirmedDate: availDate, confirmedFrom: availFrom, confirmedTo: availTo, note: availNote },
                      {
                        onSuccess: () => {
                          setLoggingAvailability(false)
                          setAvailDate("")
                          setAvailFrom("")
                          setAvailTo("")
                          setAvailNote("")
                          setAvailReason("customer_followup")
                        },
                        onError: () => toast.error(t("common.actionFailed")),
                      }
                    )
                  }
                >
                  {logAvailability.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setLoggingAvailability(false)}>
                  {t("common.cancel")}
                </Button>
              </div>
            </div>
          ) : null}
        </Card>
      ) : null}

      <Card className={cn("gap-3 px-5", overrun.isOverrun && "border-danger/40 bg-danger/5")}>
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-semibold text-text">{t("service.detail.jobReport")}</h2>
          {overrun.isOverrun ? (
            <span className="rounded-full bg-danger/10 px-2.5 py-0.5 text-xs font-medium text-danger">
              {t("service.detail.overrunBy", { count: Math.round(overrun.overrunByMinutes!) })}
            </span>
          ) : null}
        </div>
        {visit ? (
          <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
            <Field label={t("service.detail.startTime")} value={visit.timer_start ? new Date(visit.timer_start).toLocaleString() : "—"} />
            <Field label={t("service.detail.closeTime")} value={visit.timer_end ? new Date(visit.timer_end).toLocaleString() : "—"} />
            <Field
              label={t("service.detail.totalTime")}
              value={
                totalMinutes != null ? (
                  <span className="flex items-center gap-1.5">
                    {t("service.detail.minutes", { count: totalMinutes })}
                    {visit?.completed_late === true ? (
                      <span className="rounded-full bg-danger/10 px-2 py-0.5 text-xs font-medium text-danger">{t("service.detail.wasLate")}</span>
                    ) : null}
                  </span>
                ) : (
                  "—"
                )
              }
            />
            <Field label={t("service.detail.charge")} value={`₹${visit.service_charge.toLocaleString("en-IN")}`} />
            <Field
              label={t("service.detail.enquiryGenerated")}
              value={visit.enquiry_generated == null ? "—" : visit.enquiry_generated ? t("common.yes") : t("common.no")}
            />
          </div>
        ) : (
          <p className="text-sm text-text-muted">{t("service.detail.noVisitYet")}</p>
        )}

        {(paymentProofs.data ?? []).length > 0 ? (
          <div className="space-y-1.5 border-t border-border pt-3">
            <p className="text-xs text-text-muted">{t("service.detail.paymentProof.title")}</p>
            <div className="flex flex-wrap gap-2">
              {paymentProofs.data!.map((p) => (
                <PaymentProofCard key={p.id} proof={p} />
              ))}
            </div>
          </div>
        ) : null}

        {/* Technician request (2026-08-07) — per-step lateness persists past
            the checklist toggle (service_sop_steps.overdue_minutes, see
            20260807140000_sop_step_overdue_minutes.sql), so it's visible
            here for admin oversight instead of only living transiently on
            the technician's own screen while a step is in progress. */}
        {(lateSopSteps?.length ?? 0) > 0 ? (
          <div className="space-y-1.5 border-t border-border pt-3">
            <p className="text-xs text-text-muted">{t("service.detail.lateSopSteps.title")}</p>
            <div className="flex flex-wrap gap-1.5">
              {lateSopSteps!.map((s) => (
                <span key={s.id} className="rounded-full bg-danger/10 px-2.5 py-1 text-xs font-medium text-danger">
                  {s.step_name} — {t("service.detail.lateSopSteps.lateBy", { minutes: s.overdue_minutes })}
                </span>
              ))}
            </div>
          </div>
        ) : null}

        {canManage && openVisit ? (
          <div className="border-t border-border pt-3">
            {!overridingOtp ? (
              <Button variant="outline" size="sm" onClick={() => setOverridingOtp(true)}>
                <KeyRound className="size-3.5" />
                {t("service.detail.overrideOtp")}
              </Button>
            ) : (
              <div className="space-y-2">
                <p className="text-xs text-text-muted">{t("service.detail.overrideOtpHint")}</p>
                <textarea
                  rows={2}
                  value={otpOverrideReason}
                  onChange={(e) => setOtpOverrideReason(e.target.value)}
                  placeholder={t("service.detail.overrideOtpReasonPlaceholder")}
                  className={textareaClass}
                />
                <div className="flex gap-2">
                  <Button
                    size="sm"
                    variant="destructive"
                    disabled={!otpOverrideReason.trim() || overrideVisitCompletion.isPending}
                    onClick={confirmOverrideOtp}
                  >
                    {overrideVisitCompletion.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("service.detail.overrideOtpConfirm")}
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => { setOverridingOtp(false); setOtpOverrideReason("") }}>
                    {t("common.cancel")}
                  </Button>
                </div>
              </div>
            )}
          </div>
        ) : null}

        <div>
          <div className="flex items-center gap-1.5 text-xs text-text-muted">
            {t("service.detail.estimatedDuration")}
            {!editingEstimate ? (
              <button type="button" onClick={startEditingEstimate} className="text-accent" title={t("service.detail.estimatedDuration")}>
                <Pencil className="size-3" />
              </button>
            ) : null}
          </div>
          {!editingEstimate ? (
            <div className="text-text">
              {ticket.estimated_duration_minutes != null ? t("service.detail.minutes", { count: ticket.estimated_duration_minutes }) : t("service.detail.estimateNotSet")}
              {allowedDuration != null && allowedDuration !== ticket.estimated_duration_minutes ? (
                <span className="ml-1.5 text-xs text-text-muted">{t("service.detail.allowedDuration", { count: allowedDuration })}</span>
              ) : null}
            </div>
          ) : (
            <div className="mt-1 flex items-center gap-2">
              <input
                type="number"
                min={1}
                value={estimateDraft}
                onChange={(e) => setEstimateDraft(e.target.value)}
                placeholder={t("service.detail.estimateNotSet")}
                className="h-8 w-28 rounded-xl border border-border bg-surface px-2.5 text-sm text-text outline-none"
              />
              <Button size="xs" disabled={updateEstimate.isPending} onClick={saveEstimate}>
                {updateEstimate.isPending ? <Loader2 className="size-3 animate-spin" /> : t("common.save")}
              </Button>
              <Button size="xs" variant="ghost" onClick={() => setEditingEstimate(false)}>
                {t("common.cancel")}
              </Button>
            </div>
          )}
        </div>
      </Card>

      <Card className="gap-3 px-5">
        <h2 className="text-sm font-semibold text-text">{t("service.detail.evidence.title")}</h2>
        {evidenceLoading ? (
          <div className="flex items-center gap-2 py-3 text-sm text-text-muted">
            <Loader2 className="size-4 animate-spin text-accent" />
            {t("service.detail.evidence.loading")}
          </div>
        ) : evidenceError || !evidence ? (
          <div className="flex flex-col items-center gap-2 py-3 text-center">
            <TriangleAlert className="size-5 text-danger" />
            <p className="text-sm text-text-muted">{t("service.detail.evidence.loadFailed")}</p>
            <Button variant="outline" size="xs" onClick={() => refetchEvidence()}>
              {t("common.retry")}
            </Button>
          </div>
        ) : evidence.visits.length === 0 ? (
          <p className="text-sm text-text-muted">{t("service.detail.evidence.noVisits")}</p>
        ) : (
          <div className="space-y-5">
            {evidence.visits.map((v, idx) => (
              <div key={v.id} className={idx > 0 ? "space-y-3 border-t border-border pt-4" : "space-y-3"}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <h3 className="text-sm font-medium text-text">
                    {t("service.detail.evidence.visitLabel", { n: evidence.visits.length - idx })}
                    {" · "}
                    {v.technicians?.profiles?.full_name ?? "—"}
                  </h3>
                  <span className="text-xs text-text-muted">{v.timer_start ? new Date(v.timer_start).toLocaleString() : "—"}</span>
                </div>

                <div>
                  <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.photos")}</div>
                  {v.before_image_url || v.after_image_url ? (
                    <div className="grid grid-cols-2 gap-2">
                      <div>
                        <div className="mb-1 text-[11px] text-text-muted">{t("service.detail.beforeImage")}</div>
                        {v.before_image_url ? (
                          <img
                            src={v.before_image_url}
                            alt={t("service.detail.beforeImage")}
                            className="h-32 w-full rounded-lg border border-border object-cover"
                          />
                        ) : (
                          <div className="flex h-32 items-center justify-center rounded-lg border border-dashed border-border text-xs text-text-muted">—</div>
                        )}
                      </div>
                      <div>
                        <div className="mb-1 text-[11px] text-text-muted">{t("service.detail.afterImage")}</div>
                        {v.after_image_url ? (
                          <img
                            src={v.after_image_url}
                            alt={t("service.detail.afterImage")}
                            className="h-32 w-full rounded-lg border border-border object-cover"
                          />
                        ) : (
                          <div className="flex h-32 items-center justify-center rounded-lg border border-dashed border-border text-xs text-text-muted">—</div>
                        )}
                      </div>
                    </div>
                  ) : (
                    <p className="text-xs text-text-muted">{t("service.detail.evidence.noPhotos")}</p>
                  )}
                </div>

                {v.arrival_selfie_url ? (
                  <div>
                    <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.arrivalSelfie")}</div>
                    <img
                      src={v.arrival_selfie_url}
                      alt={t("service.detail.evidence.arrivalSelfie")}
                      className="h-20 w-20 rounded-lg border border-border object-cover"
                    />
                  </div>
                ) : null}

                {v.evidence_photo_urls.length > 0 ? (
                  <div>
                    <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.additionalPhotos")}</div>
                    <div className="grid grid-cols-3 gap-2 sm:w-64">
                      {v.evidence_photo_urls.map((url, i) => (
                        <img key={i} src={url} alt="" className="aspect-square w-full rounded-lg border border-border object-cover" />
                      ))}
                    </div>
                  </div>
                ) : null}

                {v.tech_sign_url || v.customer_sign_url ? (
                  <div>
                    <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.signatures")}</div>
                    <div className="grid grid-cols-2 gap-2 sm:w-64">
                      <div>
                        <div className="mb-1 text-[11px] text-text-muted">{t("service.detail.evidence.techSignature")}</div>
                        {v.tech_sign_url ? (
                          <img
                            src={v.tech_sign_url}
                            alt={t("service.detail.evidence.techSignature")}
                            className="h-16 w-full rounded-lg border border-border bg-white object-contain"
                          />
                        ) : (
                          <div className="flex h-16 items-center justify-center rounded-lg border border-dashed border-border text-xs text-text-muted">—</div>
                        )}
                      </div>
                      <div>
                        <div className="mb-1 text-[11px] text-text-muted">{t("service.detail.evidence.customerSignature")}</div>
                        {v.customer_sign_url ? (
                          <img
                            src={v.customer_sign_url}
                            alt={t("service.detail.evidence.customerSignature")}
                            className="h-16 w-full rounded-lg border border-border bg-white object-contain"
                          />
                        ) : (
                          <div className="flex h-16 items-center justify-center rounded-lg border border-dashed border-border text-xs text-text-muted">—</div>
                        )}
                      </div>
                    </div>
                  </div>
                ) : null}

                {v.ro_checklists ? (
                  <div>
                    <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.roChecklist")}</div>
                    <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
                      <Field label={t("service.detail.evidence.tdsBefore")} value={v.ro_checklists.tds_before != null ? String(v.ro_checklists.tds_before) : "—"} />
                      <Field label={t("service.detail.evidence.tdsAfter")} value={v.ro_checklists.tds_after != null ? String(v.ro_checklists.tds_after) : "—"} />
                      <Field
                        label={t("service.detail.evidence.tankCleaned")}
                        value={v.ro_checklists.tank_cleaned == null ? "—" : v.ro_checklists.tank_cleaned ? t("common.yes") : t("common.no")}
                      />
                      <Field
                        label={t("service.detail.evidence.productExplained")}
                        value={v.ro_checklists.product_explained == null ? "—" : v.ro_checklists.product_explained ? t("common.yes") : t("common.no")}
                      />
                      <Field label={t("service.detail.evidence.clientName")} value={v.ro_checklists.client_name || "—"} />
                    </div>
                  </div>
                ) : null}

                {v.notes ? (
                  <div>
                    <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.visitNotes")}</div>
                    <p className="whitespace-pre-wrap rounded-lg border border-border bg-surface-alt p-2.5 text-sm text-text">{v.notes}</p>
                  </div>
                ) : null}

                <div>
                  <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.sparesUsed")}</div>
                  {v.service_spares_used.length > 0 ? (
                    <div className="overflow-hidden rounded-lg border border-border">
                      <table className="w-full text-sm">
                        <thead className="bg-surface-alt text-xs text-text-muted">
                          <tr>
                            <th className="px-2 py-1 text-left font-medium">{t("service.detail.evidence.spareName")}</th>
                            <th className="px-2 py-1 text-left font-medium">{t("service.detail.evidence.spareSku")}</th>
                            <th className="px-2 py-1 text-right font-medium">{t("service.detail.evidence.spareQty")}</th>
                            <th className="px-2 py-1 text-right font-medium">{t("service.detail.evidence.spareCost")}</th>
                          </tr>
                        </thead>
                        <tbody>
                          {v.service_spares_used.map((s) => (
                            <tr key={s.id} className="border-t border-border">
                              <td className="px-2 py-1 text-text">{s.spares?.name ?? "—"}</td>
                              <td className="px-2 py-1 text-text">{s.spares?.sku ?? "—"}</td>
                              <td className="px-2 py-1 text-right text-text">{s.qty}</td>
                              <td className="px-2 py-1 text-right text-text">₹{s.cost.toLocaleString("en-IN")}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  ) : (
                    <p className="text-xs text-text-muted">{t("service.detail.evidence.noSpares")}</p>
                  )}
                </div>

                <div>
                  <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.gpsTrail")}</div>
                  {v.locations.length > 0 ? (
                    <ul className="max-h-32 space-y-0.5 overflow-y-auto rounded-lg border border-border p-2 text-xs text-text-muted">
                      {v.locations.map((loc) => (
                        <li key={loc.id}>
                          {loc.lat}, {loc.lng} @ {new Date(loc.recorded_at).toLocaleTimeString()}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="text-xs text-text-muted">{t("service.detail.evidence.noGps")}</p>
                  )}
                </div>

                <div>
                  <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.attendanceSelfie")}</div>
                  {v.attendance_selfie_url ? (
                    <img
                      src={v.attendance_selfie_url}
                      alt={t("service.detail.evidence.attendanceSelfie")}
                      className="h-20 w-20 rounded-lg border border-border object-cover"
                    />
                  ) : (
                    <p className="text-xs text-text-muted">{t("service.detail.evidence.noSelfie")}</p>
                  )}
                </div>
              </div>
            ))}

            <div className="border-t border-border pt-4">
              <div className="mb-1 text-xs text-text-muted">{t("service.detail.evidence.invoice")}</div>
              {evidence.invoice ? (
                <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
                  <Field label={t("service.detail.evidence.invoiceAmount")} value={`₹${evidence.invoice.total.toLocaleString("en-IN")}`} />
                  <Field label={t("service.detail.evidence.invoiceDate")} value={new Date(evidence.invoice.created_at).toLocaleDateString()} />
                  <Field
                    label={t("sales.invoice.paymentMethod")}
                    value={evidence.invoice.payment_method ? t(`sales.payment.${evidence.invoice.payment_method}`) : "—"}
                  />
                  <Field label={t("service.detail.evidence.invoicePaymentStatus")} value={t(`sales.invoice.paymentStatus.${evidence.invoice.payment_status}`)} />
                </div>
              ) : (
                <p className="text-xs text-text-muted">{t("service.detail.evidence.noInvoice")}</p>
              )}
            </div>
          </div>
        )}
      </Card>
    </div>
  )
}

function Field({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div>
      <div className="text-xs text-text-muted">{label}</div>
      <div className="text-text">{value}</div>
    </div>
  )
}
