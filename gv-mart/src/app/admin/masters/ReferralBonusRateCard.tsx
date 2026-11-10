import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useProfile } from "@/hooks/useProfile"
import { useReferralBonusRates, useSetReferralBonusRate } from "@/hooks/useReferralBonusRates"
import type { ReferralSource } from "@/services/referralBonusRates"
import { getIstNow } from "@/lib/ist"

const SOURCES: ReferralSource[] = ["sale", "amc", "service"]

function money(n: number) {
  return `₹${n.toLocaleString("en-IN")}`
}

/**
 * Referral incentives, Stage 2 — master-only "Referral bonus rate" card.
 * Deliberately a NEW, separate surface from Masters > Incentive Rules
 * (IncentiveRulesTab.tsx / incentive_rules / incentive_type) per the Stage 2
 * corrections addendum: this bonus is NOT an incentive_rules row at all, it
 * lives in its own `referral_bonus_rates` table with its own master-only RPC,
 * `set_referral_bonus_rate()`. A rate is never edited in place — changing it
 * closes the current row (`effective_to`) and inserts a new one, so past
 * months' snapshotted amounts never move. See
 * _local_only/reports/referral_incentives/stage2_corrections_addendum.md.
 */
export function ReferralBonusRateCard() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id

  const { data: rates, isLoading } = useReferralBonusRates(orgId)
  const setRate = useSetReferralBonusRate()

  const [open, setOpen] = useState(false)
  const [amount, setAmount] = useState("")
  const [source, setSource] = useState<ReferralSource | "">("")
  const [error, setError] = useState<string | null>(null)

  const rows = rates ?? []
  const active = rows.filter((r) => r.effective_to === null)
  const history = rows.filter((r) => r.effective_to !== null)

  function sourceLabel(s: ReferralSource | null) {
    return s === null ? t("masters.referralBonusRate.allSources") : t(`masters.referralBonusRate.sources.${s}`)
  }

  function openDialog() {
    setAmount("")
    setSource("")
    setError(null)
    setOpen(true)
  }

  async function confirmChange() {
    setError(null)
    const amt = Number(amount)
    if (!(amt > 0) || amount.trim() === "") {
      setError(t("masters.referralBonusRate.amountInvalid"))
      return
    }
    try {
      await setRate.mutateAsync({ orgId: orgId!, amount: amt, referralSource: source === "" ? null : source })
      toast.success(t("masters.referralBonusRate.saved"))
      setOpen(false)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <Card className="gap-3 px-5">
      <div>
        <h3 className="text-[15px] font-bold text-text">{t("masters.referralBonusRate.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.referralBonusRate.note")}</p>
      </div>

      {isLoading ? (
        <div className="flex items-center gap-2 py-2 text-sm text-text-muted">
          <Loader2 className="size-4 animate-spin text-accent" />
        </div>
      ) : active.length === 0 ? (
        <p className="text-sm text-text-muted">{t("masters.referralBonusRate.noRate")}</p>
      ) : (
        <ul className="space-y-1.5">
          {active.map((r) => (
            <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-surface-alt px-3.5 py-2.5">
              <span className="text-sm font-semibold text-text">{sourceLabel(r.referral_source)}</span>
              <span className="text-sm font-bold text-success">{money(r.amount)}</span>
              <span className="text-xs text-text-muted">{t("masters.referralBonusRate.effectiveFrom", { date: r.effective_from })}</span>
            </li>
          ))}
        </ul>
      )}

      <div>
        <Button onClick={openDialog} disabled={!orgId || isLoading}>
          {t("masters.referralBonusRate.changeRate")}
        </Button>
      </div>

      {history.length > 0 ? (
        <div className="space-y-1.5 border-t border-border pt-3">
          <h4 className="text-xs font-semibold tracking-wide text-text-muted uppercase">{t("masters.referralBonusRate.history")}</h4>
          <ul className="space-y-1">
            {history.map((r) => (
              <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 text-xs text-text-muted">
                <span>{sourceLabel(r.referral_source)}</span>
                <span>{money(r.amount)}</span>
                <span>
                  {r.effective_from} → {r.effective_to}
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogTitle>{t("masters.referralBonusRate.dialogTitle")}</DialogTitle>
          <DialogDescription>{t("masters.referralBonusRate.dialogHint", { date: getIstNow().date })}</DialogDescription>
          <form
            className="space-y-3"
            onSubmit={(e) => {
              e.preventDefault()
              confirmChange()
            }}
          >
            <div className="space-y-1.5">
              <Label htmlFor="referral-bonus-amount">{t("masters.referralBonusRate.amount")}</Label>
              <Input
                id="referral-bonus-amount"
                type="number"
                min={0.01}
                step="0.01"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                autoFocus
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="referral-bonus-source">{t("masters.referralBonusRate.source")}</Label>
              <select
                id="referral-bonus-source"
                value={source}
                onChange={(e) => setSource(e.target.value as ReferralSource | "")}
                className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
              >
                <option value="">{t("masters.referralBonusRate.allSources")}</option>
                {SOURCES.map((s) => (
                  <option key={s} value={s}>
                    {t(`masters.referralBonusRate.sources.${s}`)}
                  </option>
                ))}
              </select>
            </div>
            {error ? <p className="rounded-xl bg-danger/10 px-3.5 py-2.5 text-sm text-danger">{error}</p> : null}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => setOpen(false)}>
                {t("common.cancel")}
              </Button>
              <Button type="submit" disabled={setRate.isPending}>
                {setRate.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("masters.referralBonusRate.confirm")}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </Card>
  )
}
