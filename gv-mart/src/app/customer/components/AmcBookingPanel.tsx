import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { isAmcRenewalOpen, pricePerYearOf } from "@/lib/amc-window"
import { useRenewAmcPlan } from "@/hooks/useCustomerApp"
import type { AmcPlanRow } from "@/services/customerApp"

function formatCurrency(amount: number) {
  return new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR", maximumFractionDigits: 0 }).format(amount)
}

/**
 * In-context AMC book/renew action for a single product — extracted from
 * CustomerAmcPage's old page-wide "Renew or book AMC" dropdown so the same
 * plan-picker/years/referral/confirm-pay flow can be embedded per-product on
 * both the overview cards and the detail page. Logic is unchanged from the
 * original (isAmcRenewalOpen/pricePerYearOf/useRenewAmcPlan/renew_amc_plan,
 * same simulated-payment reference), only re-scoped to a fixed productId
 * instead of a page-level <select>.
 */
export function AmcBookingPanel({
  orgId,
  customerId,
  productId,
  dueDateStr,
  bookWindowDays,
  plans,
  ctaLabel,
}: {
  orgId: string
  customerId: string
  productId: string
  dueDateStr: string | null
  bookWindowDays: number
  plans: AmcPlanRow[]
  ctaLabel: string
}) {
  const { t } = useTranslation()
  const [selectedPlanId, setSelectedPlanId] = useState("")
  const [selectedYears, setSelectedYears] = useState(1)
  const [confirming, setConfirming] = useState(false)
  const [referredByTechnicianName, setReferredByTechnicianName] = useState("")
  const renewAmc = useRenewAmcPlan(customerId)

  const { withinWindow, daysUntil } = isAmcRenewalOpen(dueDateStr, bookWindowDays, new Date())
  const selectedPlan = plans.find((p) => p.id === selectedPlanId)
  const computedTotal = selectedPlan ? pricePerYearOf(selectedPlan) * selectedYears : 0

  if (renewAmc.isSuccess) {
    return (
      <div className="mx-1 flex items-center gap-2 rounded-xl bg-success/10 px-3.5 py-2.5 text-xs text-success">
        <CheckCircle2 className="size-4 shrink-0" />
        {t("customerApp.amc.renewedInline", { date: renewAmc.data?.expiry_date ?? "" })}
      </div>
    )
  }

  return (
    <div className="space-y-3 border-t border-border px-1 pt-3">
      {!withinWindow ? (
        <p className="rounded-xl bg-warning/10 px-3.5 py-2.5 text-xs text-warning">
          {daysUntil !== null
            ? t("customerApp.amc.tooEarlyWithDays", { days: daysUntil - bookWindowDays })
            : t("customerApp.amc.tooEarly")}
        </p>
      ) : null}

      <div className="space-y-2">
        <label className="text-xs font-medium text-text-muted">{t("customerApp.amc.selectPlan")}</label>
        {plans.length === 0 ? (
          <p className="text-sm text-text-muted">{t("customerApp.amc.noPlans")}</p>
        ) : (
          plans.map((plan) => (
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
        <div className="space-y-1.5">
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
        <div className="space-y-1.5">
          <label htmlFor={`referredByTechnicianName-${productId}`} className="text-xs font-medium text-text-muted">
            {t("customerApp.amc.referredBy.label")}
          </label>
          <input
            id={`referredByTechnicianName-${productId}`}
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
          <div className="space-y-2 border-t border-border pt-3">
            <p className="text-sm text-text-muted">{t("customerApp.amc.paymentSimulatedNote")}</p>
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
                  // credentials exist in this environment. Wiring a real gateway is a
                  // follow-up that only needs to replace this onClick.
                  const simulatedPaymentReference = `SIMULATED-${Date.now()}`
                  renewAmc.mutate({
                    orgId,
                    productId,
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
          <Button className="w-full" onClick={() => setConfirming(true)}>
            {ctaLabel}
          </Button>
        )
      ) : null}
    </div>
  )
}
