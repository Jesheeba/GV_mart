import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { FileText, Loader2, Search, Trash2, UserCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useAwardReferralPoints, useDeleteLead, useMoveLeadToCustomer, useUpdateLeadStatus } from "@/hooks/useAutomation"
import { useQuotationsForLead } from "@/hooks/useQuotations"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { formatCurrency } from "@/lib/sale-calc"
import { LOST_REASON_PRESETS, lostReasonLabel, type LostReasonPreset } from "@/lib/lead-lost-reasons"
import type { LeadListItem, LeadStatus } from "@/services/automation"
import type { Enums } from "@/types/database"

const QUOTATION_STATUS_TONE: Record<string, StatusTone> = { open: "info", converted: "success", lost: "danger" }

const STAGE_BUTTONS: LeadStatus[] = ["new", "contacted", "quoted", "won", "lost"]

type QuoteItemSeed = { productId: string | null; spareId: string | null; qty: number | null }

// For a `spare`-kind lead, product_id is only the context product the spare
// belongs to (CustomerSpareEnquiryPage always sets it to resolve the spare
// picker) — it is NOT a request to buy that product, so it must not seed its
// own full-price product line alongside the spare. Rows that end up with
// neither id (e.g. a legacy lead whose spare was never resolved to a real
// spare_id) are dropped — there is nothing priced to seed.
function toQuoteItems(kind: Enums<"lead_kind"> | null, rows: QuoteItemSeed[]) {
  return rows
    .map((r) => ({ productId: kind === "spare" ? null : r.productId, spareId: r.spareId, qty: r.qty }))
    .filter((r) => r.productId || r.spareId)
}

/**
 * Lead actions card on the lead page: items, quotation, manual stage buttons,
 * referral points, move-to-customer / delete. Contact history, follow-ups and
 * outcomes live in the header / timeline / Log Outcome sheet.
 */
export function LeadDetailPanel({ lead }: { lead: LeadListItem }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const updateStatus = useUpdateLeadStatus()
  const deleteLead = useDeleteLead()
  const moveToCustomer = useMoveLeadToCustomer()
  const isMaster = profile?.role === "master"
  const closed = lead.status === "won" || lead.status === "lost"
  const [pendingRemoval, setPendingRemoval] = useState<"move" | "delete" | null>(null)
  const removalBusy = deleteLead.isPending || moveToCustomer.isPending
  const failed = (err: unknown) => toast.error(err instanceof Error && err.message ? err.message : t("common.actionFailed"))
  const awardPoints = useAwardReferralPoints()
  const leadQuotations = useQuotationsForLead(lead.id)

  const [showLostForm, setShowLostForm] = useState(false)
  const [lostPreset, setLostPreset] = useState<LostReasonPreset | "">("")
  const [lostOther, setLostOther] = useState("")
  const lostReasonValue = lostPreset === "other" ? lostOther.trim() : lostPreset

  const [showReferral, setShowReferral] = useState(false)
  const [referrerSearch, setReferrerSearch] = useState("")
  const [referrerId, setReferrerId] = useState("")
  const [referrerLabel, setReferrerLabel] = useState("")
  const [points, setPoints] = useState("50")
  const pointsNum = Number(points)
  const pointsValid = points.trim() !== "" && Number.isFinite(pointsNum) && pointsNum >= 1
  const referrerAutocomplete = useCustomerAutocomplete(orgId, referrerSearch)

  return (
    <Card className="gap-3.5 px-5">
      {(lead.lead_items ?? []).length > 0 ? (
        <p className="text-xs text-text-muted">
          {t("leads.detail.items")}: {(lead.lead_items ?? []).map((li) => li.spares?.name ?? li.products?.name).filter(Boolean).join(", ")}
        </p>
      ) : null}

      <Button
        size="sm"
        variant="outline"
        onClick={() =>
          navigate("/admin/quotations/new", {
            state: {
              leadId: lead.id,
              customerId: lead.customer_id,
              name: lead.customers?.name ?? lead.name,
              mobile: lead.mobile ?? lead.customers?.mobile ?? null,
              status: lead.status,
              // Every product/spare the enquiry asked for prefills the
              // quotation cart; falls back to the lead's own scalar columns
              // for leads created before lead_items existed.
              items: toQuoteItems(
                lead.kind,
                (lead.lead_items ?? []).length > 0
                  ? (lead.lead_items ?? []).map((li) => ({ productId: li.product_id, spareId: li.spare_id, qty: li.qty }))
                  : [{ productId: lead.product_id, spareId: lead.spare_id, qty: lead.qty }]
              ),
            },
          })
        }
      >
        <FileText className="size-3.5" />
        {t("quotations.form.create")}
      </Button>

      {leadQuotations.data && leadQuotations.data.length > 0 ? (
        <div className="space-y-1.5">
          <Label>{t("leads.detail.quotations")}</Label>
          <ul className="space-y-1.5">
            {leadQuotations.data.map((q) => (
              <li key={q.id}>
                <button
                  type="button"
                  onClick={() => navigate(`/admin/quotations/${q.id}`)}
                  className="flex w-full items-center justify-between rounded-lg bg-surface-alt px-2.5 py-2 text-xs hover:bg-surface-alt/70"
                >
                  <span className="font-medium text-text">{formatCurrency(q.total)}</span>
                  <span className="text-text-muted">{new Date(q.created_at).toLocaleDateString("en-IN", { timeZone: "Asia/Kolkata" })}</span>
                  <StatusDot tone={QUOTATION_STATUS_TONE[q.status] ?? "neutral"} label={t(`quotations.status.${q.status}`)} />
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {!closed ? (
        <div className="space-y-1.5">
          <Label>{t("leads.detail.changeStage")}</Label>
          <div className="flex flex-wrap gap-1.5">
            {STAGE_BUTTONS.map((s) => (
              <Button
                key={s}
                size="sm"
                variant={lead.status === s ? "accent" : "outline"}
                disabled={updateStatus.isPending}
                onClick={() => {
                  if (s === "lost") {
                    setShowLostForm(true)
                    return
                  }
                  setShowLostForm(false)
                  updateStatus.mutate({ leadId: lead.id, status: s }, { onError: failed })
                }}
              >
                {t(`leads.status.${s}`)}
              </Button>
            ))}
          </div>
        </div>
      ) : lead.status === "lost" && lead.lost_reason ? (
        <p className="text-xs text-text-muted">
          <span className="font-medium text-text">{t("leads.detail.lostReasonLabel")}:</span> {lostReasonLabel(lead.lost_reason, t)}
        </p>
      ) : null}

      {showLostForm && !closed ? (
        <div className="space-y-2 rounded-xl border border-border p-3">
          <Label>{t("leads.detail.lostReasonLabel")}</Label>
          <select
            value={lostPreset}
            onChange={(e) => setLostPreset(e.target.value as LostReasonPreset | "")}
            className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          >
            <option value="">{t("leads.detail.lostReasonPlaceholder")}</option>
            {LOST_REASON_PRESETS.map((r) => (
              <option key={r} value={r}>
                {t(`leads.lostReason.${r}`)}
              </option>
            ))}
          </select>
          {lostPreset === "other" ? <Input placeholder={t("leads.detail.lostReasonOtherPlaceholder")} value={lostOther} onChange={(e) => setLostOther(e.target.value)} /> : null}
          <div className="flex justify-end gap-1.5">
            <Button size="sm" variant="ghost" onClick={() => setShowLostForm(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              size="sm"
              variant="destructive"
              disabled={!lostReasonValue || updateStatus.isPending}
              onClick={() =>
                updateStatus.mutate(
                  { leadId: lead.id, status: "lost", reason: lostReasonValue },
                  {
                    onSuccess: () => {
                      setShowLostForm(false)
                      setLostPreset("")
                      setLostOther("")
                    },
                    onError: failed,
                  }
                )
              }
            >
              {updateStatus.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.detail.confirmLost")}
            </Button>
          </div>
        </div>
      ) : null}

      {lead.customer_id && lead.status === "won" ? (
        <div className="space-y-2 rounded-xl border border-border p-3">
          <div className="flex items-center justify-between">
            <Label>{t("leads.detail.referralPoints")}</Label>
            <Button size="sm" variant="ghost" onClick={() => setShowReferral((v) => !v)}>
              {showReferral ? t("common.cancel") : t("leads.detail.awardPoints")}
            </Button>
          </div>
          {showReferral ? (
            <div className="space-y-2">
              <div className="space-y-1.5">
                <Label htmlFor="referral-referrer">{t("leads.detail.referrerSearchLabel")}</Label>
                <Autocomplete
                  id="referral-referrer"
                  value={referrerId ? referrerLabel : referrerSearch}
                  onChange={(v) => {
                    setReferrerSearch(v)
                    setReferrerId("")
                  }}
                  suggestions={referrerAutocomplete.data ?? []}
                  loading={referrerAutocomplete.isFetching}
                  placeholder={t("leads.detail.referrerSearchPlaceholder")}
                  icon={<Search className="size-4" />}
                  emptyMessage={t("common.noData")}
                  getKey={(c) => c.id}
                  getLabel={(c) => (
                    <span>
                      <span className="font-medium">{c.name}</span> <span className="text-text-muted">{c.mobile}</span>
                    </span>
                  )}
                  onSelect={(c) => {
                    setReferrerId(c.id)
                    setReferrerLabel(`${c.name} · ${c.mobile}`)
                  }}
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="referral-points">{t("leads.detail.pointsLabel")}</Label>
                <Input id="referral-points" type="number" min={1} step="1" value={points} onChange={(e) => setPoints(e.target.value)} />
              </div>
              <div className="flex justify-end">
                <Button
                  size="sm"
                  disabled={!referrerId || !pointsValid || awardPoints.isPending}
                  onClick={async () => {
                    if (!pointsValid) return
                    try {
                      await awardPoints.mutateAsync({
                        orgId: orgId!,
                        customerId: referrerId,
                        points: pointsNum,
                        reason: t("leads.detail.referralReason", { name: lead.customers?.name ?? lead.name }),
                        refId: lead.id,
                      })
                      setShowReferral(false)
                      setReferrerId("")
                      setReferrerSearch("")
                    } catch {
                      toast.error(t("common.actionFailed"))
                    }
                  }}
                >
                  {awardPoints.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("common.save")}
                </Button>
              </div>
            </div>
          ) : null}
        </div>
      ) : null}

      <div className="space-y-2 rounded-xl border border-border p-3">
        <Label>{t("leads.detail.addedByMistake")}</Label>
        {pendingRemoval ? (
          <div className="space-y-2">
            <p className="text-xs text-text-muted">{pendingRemoval === "move" ? t("leads.detail.moveConfirm") : t("leads.detail.deleteConfirm")}</p>
            <div className="flex justify-end gap-1.5">
              <Button size="sm" variant="ghost" disabled={removalBusy} onClick={() => setPendingRemoval(null)}>
                {t("common.cancel")}
              </Button>
              <Button
                size="sm"
                variant={pendingRemoval === "delete" ? "destructive" : "accent"}
                disabled={removalBusy}
                onClick={() => {
                  if (pendingRemoval === "move") {
                    moveToCustomer.mutate(lead.id, {
                      onSuccess: (customerId) => {
                        toast.success(t("leads.detail.movedToast"))
                        navigate(`/admin/customers/${customerId}`)
                      },
                      onError: failed,
                    })
                  } else {
                    deleteLead.mutate(lead.id, {
                      onSuccess: () => {
                        toast.success(t("leads.detail.deletedToast"))
                        navigate("/admin/leads")
                      },
                      onError: failed,
                    })
                  }
                }}
              >
                {removalBusy ? <Loader2 className="size-3.5 animate-spin" /> : pendingRemoval === "move" ? t("leads.detail.moveToCustomer") : t("leads.detail.deleteLead")}
              </Button>
            </div>
          </div>
        ) : (
          <div className="flex flex-wrap gap-1.5">
            <Button size="sm" variant="outline" onClick={() => setPendingRemoval("move")}>
              <UserCheck className="size-3.5" />
              {t("leads.detail.moveToCustomer")}
            </Button>
            {isMaster ? (
              <Button size="sm" variant="outline" onClick={() => setPendingRemoval("delete")}>
                <Trash2 className="size-3.5" />
                {t("leads.detail.deleteLead")}
              </Button>
            ) : null}
          </div>
        )}
      </div>
    </Card>
  )
}
