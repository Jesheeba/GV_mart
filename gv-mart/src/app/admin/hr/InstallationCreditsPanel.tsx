import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { useToast } from "@/components/ui/toast-context"
import { useApproveInstallationCredit, useInstallationCredits, useVoidInstallationCredit } from "@/hooks/useHr"
import type { InstallationCreditListItem } from "@/services/hr"

function money(n: number) {
  return `₹${n.toLocaleString("en-IN")}`
}

/**
 * Batch-2 item 3 — installation incentives are credited per completed installation ticket (charge x units) and wait here
 * for the master's approval. Compute counts only approved credits; a void takes a credit out again (reason required).
 */
export function InstallationCreditsPanel({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: pending, isLoading } = useInstallationCredits(orgId, "pending")
  const approve = useApproveInstallationCredit()
  const voidCredit = useVoidInstallationCredit()
  const [voidingId, setVoidingId] = useState<string | null>(null)
  const [reason, setReason] = useState("")

  const rows: InstallationCreditListItem[] = pending ?? []
  if (!isLoading && rows.length === 0) return null

  function doApprove(id: string) {
    approve.mutate(id, { onError: () => toast.error(t("common.actionFailed")) })
  }
  function doVoid(id: string) {
    const trimmed = reason.trim()
    if (!trimmed) {
      toast.error(t("hr.incentives.credits.reasonRequired"))
      return
    }
    voidCredit.mutate(
      { creditId: id, reason: trimmed },
      {
        onSuccess: () => {
          setVoidingId(null)
          setReason("")
        },
        onError: () => toast.error(t("common.actionFailed")),
      }
    )
  }

  return (
    <Card className="gap-3 px-5">
      <div>
        <h2 className="text-sm font-semibold text-text">{t("hr.incentives.credits.title")}</h2>
        <p className="text-xs text-text-muted">{t("hr.incentives.credits.hint")}</p>
      </div>
      {isLoading ? (
        <div className="flex items-center gap-2 py-2 text-sm text-text-muted">
          <Loader2 className="size-4 animate-spin text-accent" />
        </div>
      ) : (
        <ul className="divide-y divide-border">
          {rows.map((c) => (
            <li key={c.id} className="flex flex-wrap items-center justify-between gap-2 py-2.5">
              <div className="min-w-0 text-sm">
                <div className="font-medium text-text">
                  {c.technicians?.profiles?.full_name ?? "—"} · {c.products?.name ?? "—"}
                </div>
                <div className="text-xs text-text-muted">
                  {t("hr.incentives.credits.line", { qty: c.qty, unit: money(c.unit_amount), amount: money(c.amount) })} ·{" "}
                  <Link to={`/admin/service/${c.ticket_id}`} className="text-accent underline">
                    {t("hr.incentives.credits.ticket")}
                  </Link>
                </div>
              </div>
              {voidingId === c.id ? (
                <div className="flex items-center gap-2">
                  <Input
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder={t("hr.incentives.credits.reason")}
                    className="h-8 w-56"
                  />
                  <Button size="xs" variant="destructive" disabled={voidCredit.isPending} onClick={() => doVoid(c.id)}>
                    {t("hr.incentives.credits.void")}
                  </Button>
                  <Button size="xs" variant="ghost" onClick={() => setVoidingId(null)}>
                    {t("common.cancel")}
                  </Button>
                </div>
              ) : (
                <div className="flex items-center gap-2">
                  <Button size="xs" disabled={approve.isPending} onClick={() => doApprove(c.id)}>
                    {t("hr.incentives.credits.approve")}
                  </Button>
                  <Button size="xs" variant="outline" onClick={() => { setVoidingId(c.id); setReason("") }}>
                    {t("hr.incentives.credits.void")}
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
    </Card>
  )
}
