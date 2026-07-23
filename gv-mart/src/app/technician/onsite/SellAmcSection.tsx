import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAmcPlansForTechnician, useSellAmcOnsite } from "@/hooks/useTechnician"
import { formatCurrency } from "@/lib/sale-calc"
import type { Enums } from "@/types/database"

/**
 * Build Order A2 — "a technician visiting a customer on-site can sell them
 * an AMC plan". Scoped to the current ticket's own product (must be RO —
 * AMC is RO-only everywhere in this app) rather than a free product search:
 * the technician is standing in front of that exact product, and every
 * other on-site sub-flow on this page (spares, service charges) is
 * similarly ticket-scoped. Queues through the same offline outbox as the
 * rest of this page (see queueSellAmcOnsite) — this succeeding or failing
 * is never gated on the technician having a live connection right now.
 */
export function SellAmcSection({
  orgId,
  customerId,
  productId,
  productName,
}: {
  orgId: string | undefined
  customerId: string
  productId: string
  productName: string
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const [planId, setPlanId] = useState("")
  const [paymentMethod, setPaymentMethod] = useState<Enums<"payment_method">>("cash")
  const [txnId, setTxnId] = useState("")
  const [paymentDescription, setPaymentDescription] = useState("")
  const [queued, setQueued] = useState(false)

  const plans = useAmcPlansForTechnician(orgId)
  const sellAmc = useSellAmcOnsite()

  const selectedPlan = (plans.data ?? []).find((p) => p.id === planId)
  const canSubmit = !!planId && (paymentMethod === "cash" || (txnId.trim() && paymentDescription.trim()))

  async function handleSell() {
    if (!orgId || !planId) return
    await sellAmc.mutateAsync({
      orgId,
      customerId,
      productId,
      planId,
      paymentMethod,
      txnId: paymentMethod === "transfer" ? txnId : undefined,
      paymentDescription: paymentMethod === "transfer" ? paymentDescription : undefined,
    })
    setQueued(true)
  }

  return (
    <Card className="gap-2.5">
      <button type="button" className="flex items-center gap-1.5 px-1 text-left text-sm font-semibold text-accent" onClick={() => setOpen((v) => !v)}>
        <ShieldCheck className="size-4" />
        {t("technician.onsite.sellAmc.toggle")}
      </button>
      {open ? (
        queued ? (
          <p className="flex items-center gap-1.5 px-1 text-sm text-success">
            <CheckCircle2 className="size-4" /> {t("technician.onsite.sellAmc.queued")}
          </p>
        ) : (
          <div className="space-y-3 px-1">
            <p className="text-xs text-text-muted">{t("technician.onsite.sellAmc.hint", { product: productName })}</p>

            <div className="space-y-1.5">
              <Label>{t("technician.onsite.sellAmc.plan")}</Label>
              {plans.isLoading ? (
                <p className="text-xs text-text-muted">{t("common.loading")}</p>
              ) : (plans.data ?? []).length === 0 ? (
                <p className="text-xs text-text-muted">{t("technician.onsite.sellAmc.noPlans")}</p>
              ) : (
                <div className="space-y-2">
                  {(plans.data ?? []).map((plan) => (
                    <button
                      key={plan.id}
                      type="button"
                      onClick={() => setPlanId(plan.id)}
                      className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors ${
                        planId === plan.id ? "border-accent bg-accent-soft" : "border-border"
                      }`}
                    >
                      <div className="flex items-center justify-between">
                        <span className="font-medium text-text">{plan.name}</span>
                        <span className="font-semibold text-text">{formatCurrency(plan.price_per_year != null ? plan.price_per_year * plan.years : plan.price)}</span>
                      </div>
                      <span className="text-xs text-text-muted">{t("technician.onsite.sellAmc.planDetail", { years: plan.years, visits: plan.visits_per_year })}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>

            {selectedPlan ? (
              <>
                <div className="space-y-1.5">
                  <Label>{t("technician.onsite.payment.method")}</Label>
                  <div className="flex w-fit gap-1 rounded-full bg-surface-alt p-1">
                    {(["cash", "transfer"] as const).map((m) => (
                      <button
                        key={m}
                        type="button"
                        onClick={() => setPaymentMethod(m)}
                        className={`rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${paymentMethod === m ? "bg-ink text-white" : "text-text-muted"}`}
                      >
                        {t(`technician.onsite.payment.${m}`)}
                      </button>
                    ))}
                  </div>
                </div>

                {paymentMethod === "transfer" ? (
                  <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                    <div className="space-y-1.5">
                      <Label htmlFor="amcTxnId">{t("technician.onsite.payment.txnId")}</Label>
                      <Input id="amcTxnId" value={txnId} onChange={(e) => setTxnId(e.target.value)} />
                    </div>
                    <div className="space-y-1.5">
                      <Label htmlFor="amcPaymentDescription">{t("technician.onsite.payment.description")}</Label>
                      <Input id="amcPaymentDescription" value={paymentDescription} onChange={(e) => setPaymentDescription(e.target.value)} />
                    </div>
                  </div>
                ) : null}

                <Button type="button" variant="outline" onClick={handleSell} disabled={!canSubmit || sellAmc.isPending}>
                  {sellAmc.isPending ? <Loader2 className="size-4 animate-spin" /> : t("technician.onsite.sellAmc.sell", { amount: formatCurrency(selectedPlan.price_per_year != null ? selectedPlan.price_per_year * selectedPlan.years : selectedPlan.price) })}
                </Button>
                {sellAmc.isError ? <p className="text-xs text-danger">{t("common.actionFailed")}</p> : null}
              </>
            ) : null}
          </div>
        )
      ) : null}
    </Card>
  )
}
