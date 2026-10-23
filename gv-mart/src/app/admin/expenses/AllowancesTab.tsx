import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { DatePicker } from "@/components/ui/date-picker"
import { useProfile } from "@/hooks/useProfile"
import { supabase } from "@/lib/supabase"
import { useQuery } from "@tanstack/react-query"
import { useClosePersonAllowanceRow, usePersonAllowanceHistory, useSetPersonAllowance } from "@/hooks/useMonthlyExpenses"

/** Monthly Expenses spec Unit 4 — per-person recharge allowance. Scoped to
 *  `profiles`, not `technicians` (§1.1: "not restricted to technicians"). */
export function AllowancesTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const people = useQuery({
    queryKey: ["profiles", "forAllowances", profile?.org_id],
    queryFn: async () => {
      const { data, error } = await supabase.from("profiles").select("id, full_name").eq("org_id", profile!.org_id).order("full_name")
      if (error) throw error
      return data ?? []
    },
    enabled: !!profile?.org_id,
  })
  const [selectedId, setSelectedId] = useState<string | null>(null)

  return (
    <div className="space-y-3">
      <p className="text-sm text-text-muted">{t("expenses.allowances.hint")}</p>
      <div className="space-y-2">
        {(people.data ?? []).map((person) => (
          <Card key={person.id} className="gap-2">
            <button type="button" className="flex items-center justify-between gap-2 text-left" onClick={() => setSelectedId(selectedId === person.id ? null : person.id)}>
              <span className="text-sm font-semibold text-text">{person.full_name}</span>
              <span className="text-xs text-text-muted">{t("common.tapToExpand")}</span>
            </button>
            {selectedId === person.id ? <AllowanceForm orgId={profile?.org_id} profileId={person.id} /> : null}
          </Card>
        ))}
      </div>
    </div>
  )
}

function AllowanceForm({ orgId, profileId }: { orgId: string | undefined; profileId: string }) {
  const { t } = useTranslation()
  const history = usePersonAllowanceHistory(profileId)
  const setAllowance = useSetPersonAllowance()
  const closeRow = useClosePersonAllowanceRow()
  const [amount, setAmount] = useState("0")
  const [effectiveFrom, setEffectiveFrom] = useState("")

  const current = (history.data ?? []).find((r) => !r.effective_to)

  async function submit() {
    if (!orgId || !effectiveFrom) return
    if (current) {
      const prevDay = new Date(effectiveFrom)
      prevDay.setDate(prevDay.getDate() - 1)
      await closeRow.mutateAsync({ id: current.id, effectiveTo: prevDay.toISOString().slice(0, 10), profileId })
    }
    await setAllowance.mutateAsync({ org_id: orgId, profile_id: profileId, recharge_amount: Number(amount), effective_from: effectiveFrom })
    setEffectiveFrom("")
  }

  return (
    <div className="space-y-3 border-t border-border pt-3">
      {current ? (
        <p className="text-xs text-text-muted">{t("expenses.allowances.current", { amount: current.recharge_amount })}</p>
      ) : (
        <p className="text-xs text-text-muted">{t("expenses.allowances.noRow")}</p>
      )}
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1">
          <Label htmlFor={`recharge-${profileId}`}>{t("expenses.allowances.amount")}</Label>
          <Input id={`recharge-${profileId}`} type="number" min={0} step="10" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </div>
        <div className="space-y-1">
          <Label>{t("expenses.allowances.effectiveFrom")}</Label>
          <DatePicker value={effectiveFrom} onChange={setEffectiveFrom} />
        </div>
      </div>
      <Button type="button" size="sm" disabled={!effectiveFrom || setAllowance.isPending} onClick={submit}>
        {t("expenses.allowances.save")}
      </Button>
      {current ? (
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={closeRow.isPending}
          onClick={() => closeRow.mutate({ id: current.id, effectiveTo: new Date().toISOString().slice(0, 10), profileId })}
        >
          {t("expenses.allowances.endNow")}
        </Button>
      ) : null}
    </div>
  )
}
