import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Loader2, Pencil } from "lucide-react"
import { Button } from "@/components/ui/button"
import { useToast } from "@/components/ui/toast-context"
import { useSetTicketInstallationCharge } from "@/hooks/useHr"

/**
 * Batch-2 item 3 — the per-unit installation incentive snapshotted on an installation ticket. Internal (never billed); only the
 * master can change it, and only until the ticket is completed or cancelled (the database enforces both).
 */
export function InstallationChargeRow({
  ticketId,
  amount,
  status,
  isMaster,
}: {
  ticketId: string
  amount: number | null
  status: string
  isMaster: boolean
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const setCharge = useSetTicketInstallationCharge()
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState("")
  const editable = isMaster && status !== "completed" && status !== "cancelled"

  function save() {
    const trimmed = draft.trim()
    const value = trimmed === "" ? null : Number(trimmed)
    if (value != null && (!Number.isFinite(value) || value < 0)) {
      toast.error(t("service.detail.installCharge.invalid"))
      return
    }
    setCharge.mutate(
      { ticketId, amount: value },
      { onSuccess: () => setEditing(false), onError: () => toast.error(t("common.actionFailed")) }
    )
  }

  return (
    <div>
      <div className="flex items-center gap-1.5 text-xs text-text-muted">
        {t("service.detail.installCharge.label")}
        {editable && !editing ? (
          <button
            type="button"
            onClick={() => {
              setDraft(amount != null ? String(amount) : "")
              setEditing(true)
            }}
            className="text-accent"
            title={t("service.detail.installCharge.label")}
          >
            <Pencil className="size-3" />
          </button>
        ) : null}
      </div>
      {!editing ? (
        <div className="text-text">
          {amount != null && amount > 0 ? `₹${amount.toLocaleString("en-IN")}` : t("service.detail.installCharge.none")}
          <span className="ml-1.5 text-xs text-text-muted">{t("service.detail.installCharge.internal")}</span>
        </div>
      ) : (
        <div className="mt-1 flex items-center gap-2">
          <input
            type="number"
            min={0}
            step="0.01"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            className="h-8 w-28 rounded-xl border border-border bg-surface px-2.5 text-sm text-text outline-none"
          />
          <Button size="xs" disabled={setCharge.isPending} onClick={save}>
            {setCharge.isPending ? <Loader2 className="size-3 animate-spin" /> : t("common.save")}
          </Button>
          <Button size="xs" variant="ghost" onClick={() => setEditing(false)}>
            {t("common.cancel")}
          </Button>
        </div>
      )}
    </div>
  )
}
