import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { FileText, Loader2, Search, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useAwardReferralPoints, useLeadActivities, useLogLeadActivity, useUpdateLeadStatus } from "@/hooks/useAutomation"
import { useQuotationsForLead } from "@/hooks/useQuotations"
import { StatusDot, type StatusTone } from "@/components/shared/StatusDot"
import { formatCurrency } from "@/lib/sale-calc"
import { TechnicianChip } from "./LeadBadges"
import type { LeadListItem, LeadStatus } from "@/services/automation"
import type { Enums } from "@/types/database"

const QUOTATION_STATUS_TONE: Record<string, StatusTone> = { open: "info", converted: "success", lost: "danger" }

const STATUSES: LeadStatus[] = ["new", "contacted", "quoted", "won", "lost"]
const ACTIVITY_TYPES = ["call", "note", "whatsapp", "meeting"] as const
const LOST_REASONS = ["price_too_high", "chose_competitor", "no_longer_needs", "unresponsive", "duplicate", "other"] as const

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

export function LeadDetailPanel({ lead, onClose }: { lead: LeadListItem; onClose: () => void }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const activities = useLeadActivities(lead.id)
  const logActivity = useLogLeadActivity()
  const updateStatus = useUpdateLeadStatus()
  const awardPoints = useAwardReferralPoints()
  const leadQuotations = useQuotationsForLead(lead.id)

  const [activityType, setActivityType] = useState<(typeof ACTIVITY_TYPES)[number]>("call")
  const [note, setNote] = useState("")

  const [displayStatus, setDisplayStatus] = useState<LeadStatus>(lead.status)
  const [displayLostReason, setDisplayLostReason] = useState<string | null>(lead.lost_reason)
  useEffect(() => {
    setDisplayStatus(lead.status)
    setDisplayLostReason(lead.lost_reason)
  }, [lead.id, lead.status, lead.lost_reason])

  const [showLostForm, setShowLostForm] = useState(false)
  const [lostReasonOption, setLostReasonOption] = useState<(typeof LOST_REASONS)[number] | "">("")
  const [lostReasonOther, setLostReasonOther] = useState("")
  const lostReasonText = lostReasonOption === "other" ? lostReasonOther.trim() : lostReasonOption ? t(`leads.lostReason.${lostReasonOption}`) : ""

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
      <div className="flex items-start justify-between">
        <div className="space-y-1">
          <h2 className="text-sm font-semibold text-text">{lead.customers?.name ?? lead.name}</h2>
          <p className="text-xs text-text-muted">{lead.mobile ?? lead.customers?.mobile ?? "—"}</p>
          {lead.technicians?.profiles?.full_name ? <TechnicianChip source={lead.source} name={lead.technicians.profiles.full_name} /> : null}
        </div>
        <Button size="icon-xs" variant="ghost" onClick={onClose}>
          <X className="size-4" />
        </Button>
      </div>

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
              // Spare Enquiry multi-product line items (2026-08-05) — every
              // product/spare the enquiry asked for, prefilling the
              // quotation's item cart instead of making the admin reselect.
              // Falls back to the lead's own scalar product_id/spare_id/qty
              // (kept for backward compatibility, see
              // 20260805141000_spare_enquiry_line_items.sql) for leads
              // created before the lead_items table existed, so pre-2026-08-05
              // leads that did capture a single structured item still autofill
              // instead of forcing a manual reselect.
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
                  <span className="text-text-muted">{new Date(q.created_at).toLocaleDateString("en-IN")}</span>
                  <StatusDot tone={QUOTATION_STATUS_TONE[q.status] ?? "neutral"} label={t(`quotations.status.${q.status}`)} />
                </button>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <div className="flex flex-wrap gap-1.5">
        {STATUSES.map((s) => (
          <Button
            key={s}
            size="sm"
            variant={displayStatus === s ? "accent" : "outline"}
            disabled={updateStatus.isPending}
            onClick={() => {
              if (s === "lost") {
                setShowLostForm(true)
                return
              }
              setShowLostForm(false)
              updateStatus.mutate({ leadId: lead.id, status: s }, { onSuccess: () => setDisplayStatus(s) })
            }}
          >
            {t(`leads.status.${s}`)}
          </Button>
        ))}
      </div>

      {showLostForm ? (
        <div className="space-y-2 rounded-xl border border-border p-3">
          <Label>{t("leads.detail.lostReasonLabel")}</Label>
          <select
            value={lostReasonOption}
            onChange={(e) => setLostReasonOption(e.target.value as (typeof LOST_REASONS)[number])}
            className="h-9 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
          >
            <option value="">{t("leads.detail.lostReasonPlaceholder")}</option>
            {LOST_REASONS.map((r) => (
              <option key={r} value={r}>
                {t(`leads.lostReason.${r}`)}
              </option>
            ))}
          </select>
          {lostReasonOption === "other" ? (
            <Input
              placeholder={t("leads.detail.lostReasonOtherPlaceholder")}
              value={lostReasonOther}
              onChange={(e) => setLostReasonOther(e.target.value)}
            />
          ) : null}
          <div className="flex justify-end gap-1.5">
            <Button size="sm" variant="ghost" onClick={() => setShowLostForm(false)}>
              {t("common.cancel")}
            </Button>
            <Button
              size="sm"
              variant="destructive"
              disabled={!lostReasonText || updateStatus.isPending}
              onClick={() =>
                updateStatus.mutate(
                  { leadId: lead.id, status: "lost", reason: lostReasonText },
                  {
                    onSuccess: () => {
                      setDisplayStatus("lost")
                      setDisplayLostReason(lostReasonText)
                      setShowLostForm(false)
                      setLostReasonOption("")
                      setLostReasonOther("")
                    },
                  }
                )
              }
            >
              {updateStatus.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.detail.confirmLost")}
            </Button>
          </div>
        </div>
      ) : displayStatus === "lost" && displayLostReason ? (
        <p className="text-xs text-text-muted">
          <span className="font-medium text-text">{t("leads.detail.lostReasonLabel")}:</span> {displayLostReason}
        </p>
      ) : null}

      <div className="space-y-2 rounded-xl border border-border p-3">
        <Label>{t("leads.detail.logActivity")}</Label>
        <div className="flex flex-wrap gap-1.5">
          {ACTIVITY_TYPES.map((ty) => (
            <button
              key={ty}
              type="button"
              onClick={() => setActivityType(ty)}
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${activityType === ty ? "bg-ink text-white" : "bg-surface-alt text-text-muted"}`}
            >
              {t(`leads.activityType.${ty}`)}
            </button>
          ))}
        </div>
        <Input placeholder={t("leads.detail.notePlaceholder")} value={note} onChange={(e) => setNote(e.target.value)} />
        <div className="flex justify-end">
          <Button
            size="sm"
            disabled={logActivity.isPending}
            onClick={() => {
              logActivity.mutate({ leadId: lead.id, type: activityType, note: note || null })
              setNote("")
            }}
          >
            {logActivity.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("leads.detail.addActivity")}
          </Button>
        </div>
      </div>

      <div className="space-y-1.5">
        <Label>{t("leads.detail.history")}</Label>
        {activities.isLoading ? (
          <p className="text-xs text-text-muted">{t("common.loading")}</p>
        ) : !activities.data || activities.data.length === 0 ? (
          <p className="text-xs text-text-muted">{t("leads.detail.noActivity")}</p>
        ) : (
          <ul className="space-y-1.5">
            {activities.data.map((a) => (
              <li key={a.id} className="rounded-lg bg-surface-alt px-2.5 py-2 text-xs">
                <span className="font-medium text-text">{t(`leads.activityType.${a.type}`, a.type)}</span>{" "}
                <span className="text-text-muted">{new Date(a.at).toLocaleString("en-IN")}</span>
                {a.note ? <p className="mt-0.5 text-text-muted">{a.note}</p> : null}
              </li>
            ))}
          </ul>
        )}
      </div>

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
    </Card>
  )
}
