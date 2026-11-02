import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useAssignableProfiles } from "@/hooks/useTasks"
import { useProfile } from "@/hooks/useProfile"

/**
 * Masters > Settings — the minimum-balance / minimum-age threshold and the
 * default owner sync_outstanding_tasks() uses when deciding which
 * customers get a follow-up task (see 20261204100000_sync_outstanding_tasks.sql).
 * Master-only, same self-contained card + own mutation pattern as
 * PostServiceCallsTab's SettingsCard, rather than joining the page's big
 * react-hook-form (these 3 fields have no cross-field validation with
 * anything else on that form).
 */
export function AccountsOutstandingSettingsCard() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const settings = useSettings(orgId)
  const update = useUpdateSettings(orgId)
  const assignableProfiles = useAssignableProfiles(orgId).data ?? []

  const [balance, setBalance] = useState("50")
  const [days, setDays] = useState("3")
  const [owner, setOwner] = useState("")

  useEffect(() => {
    const s = settings.data
    if (!s) return
    setBalance(String(s.min_outstanding_balance))
    setDays(String(s.min_outstanding_days))
    setOwner(s.default_accounts_owner_id ?? "")
  }, [settings.data])

  const balanceN = Number(balance)
  const daysN = Number(days)
  const valid = Number.isFinite(balanceN) && balanceN >= 0 && Number.isInteger(daysN) && daysN >= 0

  function save() {
    update.mutate(
      {
        min_outstanding_balance: balanceN,
        min_outstanding_days: daysN,
        default_accounts_owner_id: owner || null,
      },
      {
        onSuccess: () => toast.success(t("masters.accountsOutstanding.saved")),
        onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("common.actionFailed")),
      }
    )
  }

  if (settings.isLoading || !settings.data) return <Card className="px-5 py-4 text-sm text-text-muted">{t("common.loading")}</Card>

  return (
    <Card className="gap-3.5 px-5">
      <div>
        <h3 className="text-sm font-semibold text-text">{t("masters.accountsOutstanding.title")}</h3>
        <p className="text-xs text-text-muted">{t("masters.accountsOutstanding.hint")}</p>
      </div>

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        <div className="space-y-1.5">
          <Label htmlFor="ao-balance">{t("masters.accountsOutstanding.minBalance")}</Label>
          <Input id="ao-balance" type="number" min={0} step="1" value={balance} onChange={(e) => setBalance(e.target.value)} />
          <p className="text-xs text-text-muted">{t("masters.accountsOutstanding.minBalanceHint")}</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="ao-days">{t("masters.accountsOutstanding.minDays")}</Label>
          <Input id="ao-days" type="number" min={0} step="1" value={days} onChange={(e) => setDays(e.target.value)} />
          <p className="text-xs text-text-muted">{t("masters.accountsOutstanding.minDaysHint")}</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="ao-owner">{t("masters.accountsOutstanding.owner")}</Label>
          <select
            id="ao-owner"
            value={owner}
            onChange={(e) => setOwner(e.target.value)}
            className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
          >
            <option value="">{t("masters.accountsOutstanding.ownerDefault")}</option>
            {assignableProfiles.map((p) => (
              <option key={p.id} value={p.id}>
                {p.full_name}
              </option>
            ))}
          </select>
          <p className="text-xs text-text-muted">{t("masters.accountsOutstanding.ownerHint")}</p>
        </div>
      </div>

      <div className="flex justify-end">
        <Button onClick={save} disabled={!valid || update.isPending}>
          {update.isPending ? <Loader2 className="size-4 animate-spin" /> : t("common.save")}
        </Button>
      </div>
    </Card>
  )
}
