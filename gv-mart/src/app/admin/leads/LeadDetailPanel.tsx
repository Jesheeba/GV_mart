import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Search, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Autocomplete } from "@/components/shared/Autocomplete"
import { useProfile } from "@/hooks/useProfile"
import { useCustomerAutocomplete } from "@/hooks/useCustomers"
import { useAwardReferralPoints, useLeadActivities, useLogLeadActivity, useUpdateLeadStatus } from "@/hooks/useAutomation"
import type { LeadListItem, LeadStatus } from "@/services/automation"

const STATUSES: LeadStatus[] = ["new", "contacted", "quoted", "won", "lost"]
const ACTIVITY_TYPES = ["call", "note", "whatsapp", "meeting"] as const

export function LeadDetailPanel({ lead, onClose }: { lead: LeadListItem; onClose: () => void }) {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const activities = useLeadActivities(lead.id)
  const logActivity = useLogLeadActivity()
  const updateStatus = useUpdateLeadStatus()
  const awardPoints = useAwardReferralPoints()

  const [activityType, setActivityType] = useState<(typeof ACTIVITY_TYPES)[number]>("call")
  const [note, setNote] = useState("")

  const [showReferral, setShowReferral] = useState(false)
  const [referrerSearch, setReferrerSearch] = useState("")
  const [referrerId, setReferrerId] = useState("")
  const [referrerLabel, setReferrerLabel] = useState("")
  const [points, setPoints] = useState("50")
  const referrerAutocomplete = useCustomerAutocomplete(orgId, referrerSearch)

  return (
    <Card className="gap-3.5">
      <div className="flex items-start justify-between">
        <div>
          <h2 className="text-sm font-semibold text-text">{lead.customers?.name ?? lead.name}</h2>
          <p className="text-xs text-text-muted">{lead.mobile ?? lead.customers?.mobile ?? "—"}</p>
        </div>
        <Button size="icon-xs" variant="ghost" onClick={onClose}>
          <X className="size-4" />
        </Button>
      </div>

      <div className="flex flex-wrap gap-1.5">
        {STATUSES.map((s) => (
          <Button
            key={s}
            size="sm"
            variant={lead.status === s ? "accent" : "outline"}
            disabled={updateStatus.isPending}
            onClick={() => updateStatus.mutate({ leadId: lead.id, status: s })}
          >
            {t(`leads.status.${s}`)}
          </Button>
        ))}
      </div>

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
              <Autocomplete
                value={referrerId ? referrerLabel : referrerSearch}
                onChange={(v) => {
                  setReferrerSearch(v)
                  setReferrerId("")
                }}
                suggestions={referrerAutocomplete.data ?? []}
                loading={referrerAutocomplete.isFetching}
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
              <Input type="number" min={1} value={points} onChange={(e) => setPoints(e.target.value)} />
              <div className="flex justify-end">
                <Button
                  size="sm"
                  disabled={!referrerId || !points || awardPoints.isPending}
                  onClick={async () => {
                    await awardPoints.mutateAsync({
                      orgId: orgId!,
                      customerId: referrerId,
                      points: Number(points) || 0,
                      reason: t("leads.detail.referralReason", { name: lead.customers?.name ?? lead.name }),
                      refId: lead.id,
                    })
                    setShowReferral(false)
                    setReferrerId("")
                    setReferrerSearch("")
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
