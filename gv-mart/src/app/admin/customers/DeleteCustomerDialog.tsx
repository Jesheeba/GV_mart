import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useCustomerDeleteImpact, useDeleteCustomer } from "@/hooks/useCustomers"
import type { CustomerDeleteImpact } from "@/services/customers"

const IMPACT_KEYS = ["tickets", "amc_contracts", "warranties", "rental_contracts", "quotations", "addresses", "members"] as const

/**
 * Master-only hard delete. The Delete button stays disabled until the exact
 * customer name is typed; the server re-checks the name, refuses customers
 * with invoices or an app login, and lists what the delete will remove.
 */
export function DeleteCustomerDialog({
  customer,
  open,
  onClose,
}: {
  customer: { id: string; name: string }
  open: boolean
  onClose: () => void
}) {
  const { t } = useTranslation()
  const { toast } = useToast()
  const navigate = useNavigate()
  const impact = useCustomerDeleteImpact(customer.id, open)
  const deleteCustomer = useDeleteCustomer()
  const [typed, setTyped] = useState("")

  useEffect(() => {
    if (!open) setTyped("")
  }, [open])

  const data: CustomerDeleteImpact | undefined = impact.data
  const blocked = data ? data.invoices > 0 || data.has_login : false
  const nameMatches = typed.trim() === customer.name.trim()
  const removing = IMPACT_KEYS.filter((k) => (data?.[k] ?? 0) > 0)

  return (
    <Dialog open={open} onOpenChange={(o) => !o && !deleteCustomer.isPending && onClose()}>
      <DialogContent className="max-w-md">
        <DialogTitle>{t("customers.delete.title")}</DialogTitle>
        <DialogDescription>{t("customers.delete.warning", { name: customer.name })}</DialogDescription>

        {impact.isLoading ? (
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        ) : impact.isError ? (
          <p className="text-sm text-danger">{t("common.actionFailed")}</p>
        ) : blocked ? (
          <div className="space-y-1 rounded-xl border border-danger/30 bg-danger/10 p-3 text-sm text-danger">
            {data!.invoices > 0 ? <p>{t("customers.delete.blockedInvoices", { count: data!.invoices })}</p> : null}
            {data!.has_login ? <p>{t("customers.delete.blockedLogin")}</p> : null}
          </div>
        ) : (
          <>
            {removing.length > 0 ? (
              <div className="rounded-xl border border-border bg-surface-alt p-3">
                <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-text-muted">{t("customers.delete.willRemove")}</p>
                <ul className="space-y-0.5 text-sm text-text">
                  {removing.map((k) => (
                    <li key={k}>
                      {data![k]} × {t(`customers.delete.impact.${k}`)}
                    </li>
                  ))}
                </ul>
              </div>
            ) : (
              <p className="text-sm text-text-muted">{t("customers.delete.nothingElse")}</p>
            )}

            <div className="space-y-1.5">
              <Label htmlFor="delete-customer-name">{t("customers.delete.typeName", { name: customer.name })}</Label>
              <Input
                id="delete-customer-name"
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                placeholder={customer.name}
                autoComplete="off"
              />
            </div>
          </>
        )}

        <div className="flex justify-end gap-1.5">
          <Button variant="ghost" disabled={deleteCustomer.isPending} onClick={onClose}>
            {t("common.cancel")}
          </Button>
          {!blocked && !impact.isError ? (
            <Button
              variant="destructive"
              disabled={!nameMatches || impact.isLoading || deleteCustomer.isPending}
              onClick={() =>
                deleteCustomer.mutate(
                  { customerId: customer.id, confirmName: typed },
                  {
                    onSuccess: () => {
                      toast.success(t("customers.delete.deleted"))
                      onClose()
                      navigate("/admin/customers")
                    },
                    onError: (err) => toast.error(err instanceof Error && err.message ? err.message : t("common.actionFailed")),
                  }
                )
              }
            >
              {deleteCustomer.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customers.delete.confirm")}
            </Button>
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  )
}
