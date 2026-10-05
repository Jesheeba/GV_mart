import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { incentiveRulesHooks } from "@/hooks/useMasters"
import type { IncentiveRuleWithActive } from "@/services/masters"

/** Master control for the flat 'installation' incentive rule (incentive_rules,
 * type='installation'): amount, monthly threshold and an on/off switch. Paid once
 * per technician per month, in addition to the per-unit rates below. Changes
 * apply from the next incentive computation; months already computed are never
 * touched (compute_incentives only inserts). */
export function FlatInstallationBonusCard({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: rules, isLoading } = incentiveRulesHooks.useList(orgId)
  const createMut = incentiveRulesHooks.useCreate()
  const updateMut = incentiveRulesHooks.useUpdate()

  const rule = ((rules ?? []) as IncentiveRuleWithActive[]).find((r) => r.type === "installation")
  const [amount, setAmount] = useState("")
  const [threshold, setThreshold] = useState("")
  const [active, setActive] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (rule) {
      setAmount(String(rule.amount))
      setThreshold(String(rule.threshold))
      setActive(rule.is_active)
    }
  }, [rule?.id, rule?.amount, rule?.threshold, rule?.is_active]) // eslint-disable-line react-hooks/exhaustive-deps

  async function save() {
    setError(null)
    const amt = Number(amount)
    const thr = Number(threshold)
    if (!(amt >= 0) || amount.trim() === "") return setError(t("masters.installationRates.flat.amountInvalid"))
    if (!Number.isInteger(thr) || thr < 1) return setError(t("masters.installationRates.flat.thresholdInvalid"))
    try {
      if (rule) {
        await updateMut.mutateAsync({ id: rule.id, patch: { amount: amt, threshold: thr, is_active: active } as never })
      } else {
        await createMut.mutateAsync({ org_id: orgId!, type: "installation", amount: amt, threshold: thr, is_active: active } as never)
      }
      toast.success(t("masters.installationRates.flat.saved"))
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const busy = createMut.isPending || updateMut.isPending

  return (
    <Card className="gap-3 px-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-[15px] font-bold text-text">{t("masters.installationRates.flat.title")}</h3>
        <label className="flex items-center gap-2 text-sm font-medium text-text">
          <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} className="size-4" disabled={isLoading || busy} />
          {t("masters.installationRates.flat.active")}
        </label>
      </div>
      <p className="text-xs text-text-muted">{t("masters.installationRates.flat.note")}</p>
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label htmlFor="flat-bonus-amount">{t("masters.installationRates.flat.amount")}</Label>
          <Input id="flat-bonus-amount" type="number" min={0} step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={isLoading} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="flat-bonus-threshold">{t("masters.installationRates.flat.threshold")}</Label>
          <Input id="flat-bonus-threshold" type="number" min={1} step="1" value={threshold} onChange={(e) => setThreshold(e.target.value)} disabled={isLoading} />
        </div>
        <div className="flex items-end">
          <Button onClick={save} disabled={!orgId || isLoading || busy}>
            {busy ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
          </Button>
        </div>
      </div>
      {error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{error}</p> : null}
    </Card>
  )
}
