import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { CheckCircle2, Loader2, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { isAmcRenewalOpen, pricePerYearOf } from "@/lib/amc-window"
import {
  useAmcPlans,
  useCustomerAppSettings,
  useMyAmcContracts,
  useMyCustomerId,
  useMyWarranties,
  useOwnedProducts,
  useRenewAmcPlan,
} from "@/hooks/useCustomerApp"

function formatCurrency(amount: number) {
  return new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(amount)
}

export function CustomerAmcPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: amcContracts, isLoading: loadingAmc, isError: errorAmc, refetch: refetchAmc } = useMyAmcContracts(customerId)
  const { data: warranties, isLoading: loadingW } = useMyWarranties(customerId)
  const { data: roProducts, isLoading: loadingProducts } = useOwnedProducts(orgId)
  const { data: settings } = useCustomerAppSettings(orgId)
  const { data: plans, isLoading: loadingPlans } = useAmcPlans(orgId)

  const [selectedProductId, setSelectedProductId] = useState("")
  const [selectedPlanId, setSelectedPlanId] = useState("")
  const [selectedYears, setSelectedYears] = useState(1)
  const [confirming, setConfirming] = useState(false)
  // Build Order A2 — optional technician-name referral, resolved server-side
  // to leads.owner_id by renew_amc_plan (see services/customerApp.ts).
  const [referredByTechnicianName, setReferredByTechnicianName] = useState("")

  const renewAmc = useRenewAmcPlan(customerId)

  const isLoading = loadingId || loadingAmc || loadingW || loadingProducts || loadingPlans
  if (isLoading) return <FullPageLoader label={t("common.loading")} />
  if (errorAmc) {
    return <FullPageError message={t("customerApp.amc.loadError")} onRetry={() => refetchAmc()} retryLabel={t("common.retry")} />
  }

  const bookWindowDays = settings?.amc_book_window_days ?? 30
  const today = new Date()
  const roOwned = (roProducts ?? []).filter((p) => p.category === "ro")

  const contractsByProduct = new Map((amcContracts ?? []).map((c) => [c.product_id, c]))

  function windowInfo(nextDueDateStr: string | null | undefined) {
    return isAmcRenewalOpen(nextDueDateStr, bookWindowDays, today)
  }

  const selectedProduct = roOwned.find((p) => p.id === selectedProductId)
  const existingContract = selectedProductId ? contractsByProduct.get(selectedProductId) : undefined
  const existingWarranty = (warranties ?? []).find((w) => w.product_id === selectedProductId)
  const dueDateStr = existingContract?.expiry_date ?? existingWarranty?.expiry_date ?? null
  const { withinWindow, daysUntil } = windowInfo(dueDateStr)

  const selectedPlan = (plans ?? []).find((p) => p.id === selectedPlanId)
  // Fix 1: "choose how many years, price computes" — price_per_year (falling
  // back to price/years for any plan created before that column existed)
  // times the customer-chosen years, defaulting to the plan's own years.
  const computedTotal = selectedPlan ? pricePerYearOf(selectedPlan) * selectedYears : 0

  if (renewAmc.isSuccess) {
    return (
      <div className="flex min-h-[70vh] items-center justify-center pt-2">
        <Card className="max-w-md items-center gap-3 py-8 text-center">
          <span className="flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 className="size-6" />
          </span>
          <h1 className="px-1 text-lg font-bold text-text">{t("customerApp.amc.renewedTitle")}</h1>
          <p className="px-1 text-sm text-text-muted">
            {t("customerApp.amc.renewedBody", { date: renewAmc.data?.expiry_date ?? "" })}
          </p>
          <Button onClick={() => navigate("/customer/products")}>{t("customerApp.amc.viewMyProducts")}</Button>
        </Card>
      </div>
    )
  }

  return (
    <div className="space-y-4 pb-4 pt-2">
      <h1 className="text-xl font-bold text-text">{t("customerApp.amc.title")}</h1>

      {/* Existing coverage */}
      <div className="space-y-2">
        <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.amc.yourCoverage")}</h2>
        {(amcContracts ?? []).length === 0 && (warranties ?? []).length === 0 ? (
          <Card className="items-center gap-1.5 py-6 text-center">
            <ShieldCheck className="size-6 text-text-muted" />
            <p className="text-sm text-text-muted">{t("customerApp.amc.noCoverage")}</p>
          </Card>
        ) : (
          <>
            {(amcContracts ?? []).map((c) => (
              <Card key={c.id} size="sm" className="gap-1.5">
                <div className="flex items-center justify-between px-1">
                  <p className="text-sm font-medium text-text">{c.products?.name}</p>
                  <StatusDot tone={c.status === "active" ? "success" : c.status === "due_soon" ? "warning" : "danger"} label={t(`customerApp.amc.status.${c.status}`)} />
                </div>
                <p className="px-1 text-xs text-text-muted">{t("customerApp.amc.planLabel", { plan: c.amc_plans?.name ?? "—" })}</p>
                <p className="px-1 text-xs text-text-muted">{t("customerApp.amc.startedOn", { date: c.start_date })}</p>
                <p className="px-1 text-xs text-text-muted">{t("customerApp.amc.expiresOn", { date: c.expiry_date })}</p>
                {c.next_service_date ? <p className="px-1 text-xs text-text-muted">{t("customerApp.amc.nextServiceOn", { date: c.next_service_date })}</p> : null}
              </Card>
            ))}
            {(warranties ?? []).map((w) => (
              <Card key={w.id} size="sm" className="gap-1.5">
                <div className="flex items-center justify-between px-1">
                  <p className="text-sm font-medium text-text">{w.products?.name}</p>
                  <StatusDot tone="info" label={t("customerApp.amc.warrantyCoverage")} />
                </div>
                <p className="px-1 text-xs text-text-muted">{t("customerApp.amc.expiresOn", { date: w.expiry_date })}</p>
              </Card>
            ))}
          </>
        )}
      </div>

      {/* Renew / book */}
      <Card className="gap-3">
        <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.amc.renewOrBook")}</h2>

        {roOwned.length === 0 ? (
          <p className="px-1 text-sm text-text-muted">{t("customerApp.amc.noRoProducts")}</p>
        ) : (
          <div className="space-y-1 px-1">
            <label className="text-xs font-medium text-text-muted">{t("customerApp.amc.selectProduct")}</label>
            <select
              value={selectedProductId}
              onChange={(e) => {
                setSelectedProductId(e.target.value)
                setSelectedPlanId("")
                setConfirming(false)
              }}
              className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
            >
              <option value="">{t("customerApp.amc.selectProductPlaceholder")}</option>
              {roOwned.map((p) => (
                <option key={p.id} value={p.id}>
                  {[p.name, p.brands?.name, p.models?.name].filter(Boolean).join(" · ")}
                </option>
              ))}
            </select>
          </div>
        )}

        {selectedProduct ? (
          <>
            {!withinWindow ? (
              <p className="mx-1 rounded-xl bg-warning/10 px-3.5 py-2.5 text-xs text-warning">
                {daysUntil !== null
                  ? t("customerApp.amc.tooEarlyWithDays", { days: daysUntil - bookWindowDays })
                  : t("customerApp.amc.tooEarly")}
              </p>
            ) : null}

            <div className="space-y-2 px-1">
              <label className="text-xs font-medium text-text-muted">{t("customerApp.amc.selectPlan")}</label>
              {(plans ?? []).length === 0 ? (
                <p className="text-sm text-text-muted">{t("customerApp.amc.noPlans")}</p>
              ) : (
                (plans ?? []).map((plan) => (
                  <button
                    key={plan.id}
                    type="button"
                    disabled={!withinWindow}
                    onClick={() => {
                      setSelectedPlanId(plan.id)
                      setSelectedYears(plan.years)
                      setConfirming(false)
                    }}
                    className={`block w-full rounded-xl border px-3.5 py-2.5 text-left text-sm transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${
                      selectedPlanId === plan.id ? "border-accent bg-accent-soft" : "border-border"
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <span className="font-medium text-text">{plan.name}</span>
                      <span className="font-semibold text-text">
                        {formatCurrency(pricePerYearOf(plan))}
                        <span className="text-xs font-normal text-text-muted">{t("customerApp.amc.perYear")}</span>
                      </span>
                    </div>
                    <span className="text-xs text-text-muted">
                      {t("customerApp.amc.planDetail", { years: plan.years, visits: plan.visits_per_year })}
                    </span>
                  </button>
                ))
              )}
            </div>

            {selectedPlan && withinWindow ? (
              <div className="space-y-1.5 px-1">
                <label className="text-xs font-medium text-text-muted">{t("customerApp.amc.years")}</label>
                <input
                  type="number"
                  min={1}
                  step={1}
                  value={selectedYears}
                  onChange={(e) => setSelectedYears(Math.max(1, Number(e.target.value) || 1))}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
                <p className="text-sm font-medium text-text">{t("customerApp.amc.totalPrice", { amount: formatCurrency(computedTotal) })}</p>
              </div>
            ) : null}

            {selectedPlan && withinWindow ? (
              <div className="space-y-1.5 px-1">
                <label htmlFor="referredByTechnicianName" className="text-xs font-medium text-text-muted">
                  {t("customerApp.amc.referredBy.label")}
                </label>
                <input
                  id="referredByTechnicianName"
                  type="text"
                  value={referredByTechnicianName}
                  onChange={(e) => setReferredByTechnicianName(e.target.value)}
                  placeholder={t("customerApp.amc.referredBy.placeholder")}
                  className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none"
                />
                <p className="text-xs text-text-muted">{t("customerApp.amc.referredBy.hint")}</p>
              </div>
            ) : null}

            {selectedPlan && withinWindow ? (
              confirming ? (
                <div className="space-y-2 border-t border-border px-1 pt-3">
                  <p className="text-sm text-text-muted">
                    {t("customerApp.amc.paymentSimulatedNote")}
                  </p>
                  {renewAmc.isError ? <p className="text-xs text-danger">{(renewAmc.error as Error).message}</p> : null}
                  <div className="flex justify-end gap-2">
                    <Button variant="ghost" size="sm" onClick={() => setConfirming(false)} disabled={renewAmc.isPending}>
                      {t("common.cancel")}
                    </Button>
                    <Button
                      size="sm"
                      disabled={renewAmc.isPending}
                      onClick={() => {
                        // SIMULATED payment confirmation — v2.2 flags AMC renewal as the
                        // one payment-gateway touchpoint in this app, but no real merchant
                        // credentials exist in this environment. This generates a
                        // placeholder reference and calls the renew RPC directly; wiring an
                        // actual gateway (Razorpay/Stripe/etc.) is a follow-up that only
                        // needs to replace this onClick with a real checkout redirect before
                        // calling renewAmc.mutate with the gateway's payment reference.
                        const simulatedPaymentReference = `SIMULATED-${Date.now()}`
                        renewAmc.mutate({
                          orgId: orgId!,
                          productId: selectedProductId,
                          planId: selectedPlanId,
                          paymentReference: simulatedPaymentReference,
                          years: selectedYears,
                          referredByTechnicianName: referredByTechnicianName.trim() || undefined,
                        })
                      }}
                    >
                      {renewAmc.isPending ? <Loader2 className="size-3.5 animate-spin" /> : t("customerApp.amc.payAmount", { amount: formatCurrency(computedTotal) })}
                    </Button>
                  </div>
                </div>
              ) : (
                <div className="px-1">
                  <Button className="w-full" onClick={() => setConfirming(true)}>
                    {t("customerApp.amc.renewNow")}
                  </Button>
                </div>
              )
            ) : null}
          </>
        ) : null}
      </Card>
    </div>
  )
}
