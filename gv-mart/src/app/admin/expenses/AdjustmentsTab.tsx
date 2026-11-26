import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { ChoiceSelect } from "@/components/shared/ChoiceSelect"
import { useProfile } from "@/hooks/useProfile"
import { supabase } from "@/lib/supabase"
import { useQuery } from "@tanstack/react-query"
import { useAddMonthlyAdjustment, useDeleteMonthlyAdjustment, useMonthlyAdjustments } from "@/hooks/useMonthlyExpenses"
import { DEDUCTION_TARGETS, type AdjustmentTarget } from "@/services/monthlyExpenses"
import { useToast } from "@/components/ui/toast-context"
import { FIELD_W } from "@/lib/fieldWidth"
import { focusChoice } from "@/lib/utils"

/** Monthly Expenses spec Unit 4/§1.7 — top-ups and exclusions, scoped (per
 *  the owner's revision) to `recharge` and `bike_allowance` only. Petrol and
 *  maintenance don't use this: verifying the claim amount is how an admin
 *  changes what's paid, and verifying at zero is how they refuse it. */
export function AdjustmentsTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [period, setPeriod] = useState(new Date().toISOString().slice(0, 7) + "-01")
  const adjustments = useMonthlyAdjustments(profile?.org_id, period)
  const people = useQuery({
    queryKey: ["profiles", "forAdjustments", profile?.org_id],
    queryFn: async () => {
      const { data, error } = await supabase.from("profiles").select("id, full_name").eq("org_id", profile!.org_id).order("full_name")
      if (error) throw error
      return data ?? []
    },
    enabled: !!profile?.org_id,
  })
  const addAdjustment = useAddMonthlyAdjustment()
  // Rework (20270101100200): the master may also omit ("Exclude") or add to ("Top up") the late and rework
  // salary deductions, and remove such a row to undo it. Those targets are master-only (RLS).
  const deleteAdjustment = useDeleteMonthlyAdjustment()
  const { toast } = useToast()
  const isMaster = profile?.role === "master"

  const [profileId, setProfileId] = useState("")
  // Both unchosen until picked (choice-no-preselect).
  const [target, setTarget] = useState<AdjustmentTarget | "">("")
  const isDeduction = !!target && DEDUCTION_TARGETS.includes(target)
  const [type, setType] = useState<"top_up" | "exclude" | "">("")
  const [choiceError, setChoiceError] = useState<"target" | "type" | null>(null)
  const [amount, setAmount] = useState("")
  const [reason, setReason] = useState("")

  async function submit() {
    if (!profile?.org_id || !profileId || !reason.trim()) return
    if (!target || !type) {
      const missing = !target ? "target" : "type"
      setChoiceError(missing)
      focusChoice(`adj-${missing}`)
      return
    }
    await addAdjustment.mutateAsync({
      orgId: profile.org_id,
      profileId,
      period,
      target,
      type,
      amount: type === "top_up" ? Number(amount) : null,
      reason: reason.trim(),
    })
    setAmount("")
    setReason("")
    setTarget("")
    setType("")
  }

  return (
    <div className="space-y-3">
      <div className="space-y-1">
        <Label htmlFor="adj-period">{t("expenses.adjustments.month")}</Label>
        <Input id="adj-period" type="month" value={period.slice(0, 7)} onChange={(e) => setPeriod(`${e.target.value}-01`)} />
      </div>

      <Card className="gap-2.5">
        <p className="text-sm font-semibold text-text">{t("expenses.adjustments.addTitle")}</p>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div className="space-y-1">
            <Label htmlFor="adj-person">{t("expenses.adjustments.person")}</Label>
            <select id="adj-person" value={profileId} onChange={(e) => setProfileId(e.target.value)} className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none">
              <option value="">{t("expenses.adjustments.selectPerson")}</option>
              {(people.data ?? []).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.full_name}
                </option>
              ))}
            </select>
          </div>
          <ChoiceSelect
            id="adj-target"
            className="space-y-1"
            label={t("expenses.adjustments.target")}
            value={target}
            options={([...(["recharge", "bike_allowance"] as const), ...(isMaster ? DEDUCTION_TARGETS : [])] as AdjustmentTarget[]).map((v) => ({
              value: v,
              label: t(`expenses.adjustments.targetValues.${v}`),
            }))}
            onChange={(v) => {
              setTarget(v)
              if (choiceError === "target") setChoiceError(null)
            }}
            error={choiceError === "target" ? t("common.chooseOption") : undefined}
          />
          <ChoiceSelect
            id="adj-type"
            className="space-y-1"
            label={t("expenses.adjustments.type")}
            value={type}
            options={[
              { value: "top_up", label: t(isDeduction ? "expenses.adjustments.addDeduction" : "expenses.adjustments.topUp") },
              { value: "exclude", label: t(isDeduction ? "expenses.adjustments.omitDeduction" : "expenses.adjustments.exclude") },
            ]}
            onChange={(v) => {
              setType(v)
              if (choiceError === "type") setChoiceError(null)
            }}
            error={choiceError === "type" ? t("common.chooseOption") : undefined}
          />
          {type === "top_up" ? (
            <div className="space-y-1">
              <Label htmlFor="adj-amount">{t("expenses.adjustments.amount")}</Label>
              <Input id="adj-amount" type="number" inputMode="numeric" min={0} step="10" className={FIELD_W.amount} value={amount} onChange={(e) => setAmount(e.target.value)} />
            </div>
          ) : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor="adj-reason">{t("expenses.adjustments.reason")}</Label>
          <Input id="adj-reason" value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
        <Button type="button" size="sm" disabled={!profileId || !reason.trim() || (type === "top_up" && !amount) || addAdjustment.isPending} onClick={submit}>
          {t("expenses.adjustments.save")}
        </Button>
      </Card>

      <div className="space-y-1.5">
        {(adjustments.data ?? []).length === 0 ? (
          <p className="text-sm text-text-muted">{t("expenses.adjustments.empty")}</p>
        ) : (
          adjustments.data!.map((adj) => (
            <Card key={adj.id} className="gap-1 py-2.5">
              <p className="text-sm text-text">
                {adj.profiles?.full_name ?? "—"} · {t(`expenses.adjustments.targetValues.${adj.adjustment_target}` as "expenses.adjustments.targetValues.recharge")} ·{" "}
                {t(`expenses.adjustments.${adj.adjustment_type === "top_up" ? "topUp" : "exclude"}`)}
                {adj.amount != null ? ` ₹${adj.amount}` : ""}
              </p>
              <p className="text-xs text-text-muted">{adj.reason}</p>
              {isMaster && DEDUCTION_TARGETS.includes(adj.adjustment_target as AdjustmentTarget) ? (
                <div>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={deleteAdjustment.isPending}
                    onClick={() => deleteAdjustment.mutate(adj.id, { onError: () => toast.error(t("common.actionFailed")) })}
                  >
                    {t("expenses.adjustments.remove")}
                  </Button>
                </div>
              ) : null}
            </Card>
          ))
        )}
      </div>
    </div>
  )
}
