import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { TriangleAlert } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { useTicketsMissingProduct } from "@/hooks/useService"

/**
 * Gate-assignment-on-product (2026-08-04): nags admins about open service
 * tickets that have neither a catalog product nor an admin-typed
 * "not in inventory" name — those tickets can't be assigned to a
 * technician (see 20260804170000_gate_assignment_on_product.sql). Mounted
 * once each in OpsDashboard and MastersPage, not globally — `open` is
 * plain local state that starts true on every mount, so simply navigating
 * back to either page re-shows the full popup; dismissing it for the
 * current visit collapses to a small persistent banner instead of
 * vanishing outright.
 */
export function MissingProductAlert({ orgId }: { orgId: string | undefined }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: tickets } = useTicketsMissingProduct(orgId)
  const [open, setOpen] = useState(true)

  const count = tickets?.length ?? 0
  if (count === 0) return null

  if (!open) {
    return (
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="mb-4 flex w-full items-center gap-2 rounded-xl border border-warning/30 bg-warning/10 px-3.5 py-2.5 text-left text-sm text-warning"
      >
        <TriangleAlert className="size-4 shrink-0" />
        <span className="flex-1">{t("service.missingProductAlert.body", { count })}</span>
        <span className="font-semibold underline">{t("service.missingProductAlert.reviewButton")}</span>
      </button>
    )
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent>
        <DialogTitle className="flex items-center gap-2">
          <TriangleAlert className="size-4 text-warning" />
          {t("service.missingProductAlert.title")}
        </DialogTitle>
        <p className="text-sm text-text-muted">{t("service.missingProductAlert.body", { count })}</p>
        <div className="space-y-1.5">
          {(tickets ?? []).map((ticket) => (
            <button
              key={ticket.id}
              type="button"
              onClick={() => navigate(`/admin/service/${ticket.id}`)}
              className="block w-full rounded-xl border border-border px-3.5 py-2.5 text-left text-sm transition-colors hover:bg-surface-alt"
            >
              <div className="font-medium text-text">{ticket.name_of_complaint || "—"}</div>
              <div className="text-xs text-text-muted">
                {[ticket.customers?.name, ticket.addresses?.area, new Date(ticket.created_at).toLocaleDateString()].filter(Boolean).join(" · ")}
              </div>
            </button>
          ))}
        </div>
        <div className="flex justify-end pt-1">
          <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
            {t("service.missingProductAlert.closeButton")}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  )
}
