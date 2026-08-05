import { useMemo, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Trophy } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { StatusDot } from "@/components/shared/StatusDot"
import { useProfile } from "@/hooks/useProfile"
import { useAuth } from "@/hooks/useAuth"
import { useActiveTechnicians, useLogReward, useRewardCandidates, useRewards } from "@/hooks/useHr"
import type { RewardCandidate, RewardCategory, RewardListItem } from "@/services/hr"

function currentMonthIso() {
  return new Date().toISOString().slice(0, 7)
}
function monthToPeriodDate(month: string) {
  return `${month}-01`
}

const CATEGORIES: RewardCategory[] = ["attendance", "highest_review", "highest_revenue", "highest_referral"]

/**
 * ADM-26. v2.2 minimums (min 51 reviews, min ₹1,50,000 revenue) are applied
 * server-side in reward_candidates() (migration
 * 20260702200200_hr_functions.sql) — a technician only appears as a
 * candidate here if they clear the bar. Logging is a plain insert into the
 * existing `rewards` table (rewards_write_ops already permits
 * is_ops_staff()); no new RPC needed for the write side.
 *
 * Client rewards spec (2026-08-04): attendance is now "full attendance + <=3h
 * late/month" (was "zero late days"), revenue combines service + sales, and
 * a 4th category (highest_referral, >= 20 cumulative Sales/Service/AMC
 * referrals) was added — see 20260804160000_reward_candidates_v2.sql.
 */
export function RewardsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const { session } = useAuth()
  const orgId = profile?.org_id
  const [month, setMonth] = useState(currentMonthIso())
  const period = monthToPeriodDate(month)

  const { data: candidates, isLoading: candidatesLoading } = useRewardCandidates(orgId, period)
  const { data: rewards, isLoading, isError, refetch } = useRewards(orgId, period)
  const { data: technicians } = useActiveTechnicians(orgId)
  const logMut = useLogReward()

  const technicianName = useMemo(() => {
    const map = new Map((technicians ?? []).map((t) => [t.id, t.full_name]))
    return (id: string) => map.get(id) ?? id
  }, [technicians])

  const candidatesByCategory = useMemo(() => {
    const map = new Map<RewardCategory, RewardCandidate[]>()
    for (const c of candidates ?? []) {
      const list = map.get(c.category) ?? []
      list.push(c)
      map.set(c.category, list)
    }
    return map
  }, [candidates])

  const alreadyGiven = useMemo(() => new Set((rewards ?? []).map((r) => `${r.category}:${r.winner_id}`)), [rewards])

  function giveReward(category: RewardCategory, technicianId: string) {
    if (!orgId || !session?.user.id) return
    logMut.mutate({ orgId, category, period, winnerId: technicianId, givenBy: session.user.id })
  }

  const columns: DataTableColumn<RewardListItem>[] = [
    { key: "category", header: t("hr.rewards.category"), render: (r) => t(`hr.rewards.categories.${r.category}`) },
    { key: "winner", header: t("hr.rewards.winner"), render: (r) => r.technicians?.profiles?.full_name ?? "—" },
    { key: "givenAt", header: t("hr.rewards.givenAt"), render: (r) => new Date(r.given_at).toLocaleDateString("en-IN") },
    { key: "note", header: t("hr.rewards.note"), render: (r) => r.note ?? "—" },
  ]

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Label htmlFor="rewards-month" className="text-sm">
          {t("hr.rewards.month")}
        </Label>
        <Input id="rewards-month" type="month" value={month} onChange={(e) => setMonth(e.target.value)} className="max-w-44" />
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {CATEGORIES.map((category) => {
          const list = candidatesByCategory.get(category) ?? []
          return (
            <Card key={category} size="default" className="gap-2 px-5">
              <div className="flex items-center gap-1.5 px-1">
                <Trophy className="size-4 text-warning" />
                <p className="text-sm font-semibold text-text">{t(`hr.rewards.categories.${category}`)}</p>
              </div>
              <p className="px-1 text-xs text-text-muted">{t(`hr.rewards.minimums.${category}`)}</p>
              {candidatesLoading ? (
                <p className="px-1 text-sm text-text-muted">{t("common.loading")}</p>
              ) : list.length === 0 ? (
                <p className="px-1 text-sm text-text-muted">{t("hr.rewards.noEligible")}</p>
              ) : (
                <div className="space-y-2 px-1">
                  {list.map((c) => {
                    const key = `${category}:${c.technician_id}`
                    const given = alreadyGiven.has(key)
                    return (
                      <div key={c.technician_id} className="flex items-center justify-between gap-2 rounded-lg border border-border p-2">
                        <div>
                          <p className="text-sm font-medium text-text">{technicianName(c.technician_id)}</p>
                          <p className="text-xs text-text-muted">{t("hr.rewards.metric", { value: c.metric })}</p>
                        </div>
                        {given ? (
                          <StatusDot tone="success" label={t("hr.rewards.given")} />
                        ) : (
                          <Button size="xs" onClick={() => giveReward(category, c.technician_id)} disabled={logMut.isPending}>
                            {logMut.isPending ? <Loader2 className="size-3 animate-spin" /> : t("hr.rewards.give")}
                          </Button>
                        )}
                      </div>
                    )
                  })}
                </div>
              )}
            </Card>
          )
        })}
      </div>

      <div>
        <p className="mb-2 text-sm font-semibold text-text">{t("hr.rewards.logTitle")}</p>
        <DataTable
          columns={columns}
          rows={rewards ?? []}
          rowKey={(r) => r.id}
          loading={isLoading}
          error={isError ? t("hr.rewards.loadFailed") : null}
          onRetry={() => refetch()}
          emptyMessage={t("hr.rewards.empty")}
        />
      </div>
    </div>
  )
}
