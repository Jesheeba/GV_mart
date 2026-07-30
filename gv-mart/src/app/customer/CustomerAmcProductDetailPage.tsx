import type { TFunction } from "i18next"
import { useTranslation } from "react-i18next"
import { useNavigate, useParams } from "react-router-dom"
import { ArrowLeft, Package, ShieldCheck } from "lucide-react"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { AmcBookingPanel } from "@/app/customer/components/AmcBookingPanel"
import {
  useAmcPlans,
  useCustomerAppSettings,
  useMyAmcContractHistory,
  useMyCustomerId,
  useOwnedProductsWithStatus,
} from "@/hooks/useCustomerApp"
import type { AmcHistoryTicket } from "@/services/customerApp"

function HistoryList({ tickets, t }: { tickets: AmcHistoryTicket[]; t: TFunction }) {
  if (tickets.length === 0) {
    return <p className="px-1 text-sm text-text-muted">{t("customerApp.amc.noHistory")}</p>
  }
  return (
    <div className="space-y-2 px-1">
      {tickets.map((ticket) => {
        const parts = ticket.service_visits.flatMap((v) => v.service_spares_used)
        return (
          <div key={ticket.id} className="space-y-1.5 rounded-xl border border-border px-3.5 py-2 text-xs">
            <div className="flex items-center justify-between">
              <span className="font-medium text-text">{new Date(ticket.created_at).toLocaleDateString()}</span>
              <StatusDot tone="success" label={t(`customerApp.bookings.status.${ticket.status}`)} />
            </div>
            {ticket.name_of_complaint ? <p className="text-text-muted">{ticket.name_of_complaint}</p> : null}
            <div>
              <p className="font-medium text-text-muted">{t("customerApp.amc.partsUsed")}</p>
              {parts.length === 0 ? (
                <p className="text-text-muted">{t("customerApp.amc.noPartsUsed")}</p>
              ) : (
                <ul className="list-inside list-disc text-text-muted">
                  {parts.map((p) => (
                    <li key={p.id}>
                      {p.spares?.name ?? "—"} × {p.qty}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}

export function CustomerAmcProductDetailPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { productId } = useParams<{ productId: string }>()
  const { customerId, orgId, isLoading: loadingId } = useMyCustomerId()
  const { data: rows, isLoading: loadingRows, isError, refetch } = useOwnedProductsWithStatus(customerId)
  const { data: settings, isLoading: loadingSettings } = useCustomerAppSettings(orgId)
  const { data: plans, isLoading: loadingPlans } = useAmcPlans(orgId)
  const { data: history, isLoading: loadingHistory } = useMyAmcContractHistory(customerId, productId)

  const isLoading = loadingId || loadingRows || loadingSettings || loadingPlans || loadingHistory
  if (isLoading) return <FullPageLoader label={t("common.loading")} />

  // The detail route only ever renders for a product in this customer's own
  // useOwnedProductsWithStatus set — never falls back to the full catalog,
  // so an unknown/not-owned productId (bad link, another customer's id)
  // simply shows the error state rather than leaking or fabricating data.
  const row = rows?.find((r) => r.product.id === productId)
  if (isError || !row) {
    return <FullPageError message={t("customerApp.amc.loadError")} onRetry={() => refetch()} retryLabel={t("common.retry")} />
  }

  const { product, amc, warranty } = row
  const isRo = product.category === "ro"
  const bookWindowDays = settings?.amc_book_window_days ?? 30
  const dueDateStr = amc?.expiry_date ?? warranty?.expiry_date ?? null
  const brandModel = [product.brands?.name, product.models?.name].filter(Boolean).join(" · ")
  const today = new Date().toISOString().slice(0, 10)

  const amcHistory = (history ?? []).filter((h) => h.type === "amc")
  const warrantyHistory = (history ?? []).filter((h) => h.type === "warranty")

  return (
    <div className="space-y-4 pb-4 pt-2">
      <button
        type="button"
        onClick={() => navigate("/customer/amc")}
        className="flex items-center gap-1.5 text-sm font-medium text-text-muted"
      >
        <ArrowLeft className="size-4" />
        {t("customerApp.amc.backToOverview")}
      </button>

      <Card className="gap-1">
        <div className="flex items-center justify-between px-1">
          <div>
            <p className="text-base font-semibold text-text">{product.name}</p>
            {brandModel ? <p className="text-xs text-text-muted">{brandModel}</p> : null}
          </div>
          <span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-accent-soft text-accent">
            <Package className="size-4" />
          </span>
        </div>
      </Card>

      {isRo ? (
        <Card className="gap-3">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.amc.currentPlan")}</h2>
          {amc ? (
            <div className="space-y-1.5 px-1 text-xs">
              <div className="flex items-center justify-between">
                <StatusDot
                  tone={amc.status === "active" ? "success" : amc.status === "due_soon" ? "warning" : "danger"}
                  label={t(`customerApp.amc.status.${amc.status}`)}
                />
                <span className="flex items-center gap-1 text-text-muted">
                  <ShieldCheck className="size-3 shrink-0" />
                  {amc.amc_plans?.name}
                </span>
              </div>
              <p className="text-text-muted">{t("customerApp.amc.startedOn", { date: amc.start_date })}</p>
              <p className="text-text-muted">{t("customerApp.amc.expiresOn", { date: amc.expiry_date })}</p>
              {amc.next_service_date ? (
                <p className="text-text-muted">{t("customerApp.amc.nextServiceOn", { date: amc.next_service_date })}</p>
              ) : null}
            </div>
          ) : (
            <div className="px-1">
              <StatusDot tone="neutral" label={t("customerApp.amc.noAmcForProduct")} />
            </div>
          )}
          <AmcBookingPanel
            orgId={orgId!}
            customerId={customerId!}
            productId={product.id}
            dueDateStr={dueDateStr}
            bookWindowDays={bookWindowDays}
            plans={plans ?? []}
            ctaLabel={amc ? t("customerApp.amc.renewNow") : t("customerApp.amc.bookNow")}
          />
        </Card>
      ) : null}

      {isRo ? (
        <Card className="gap-2">
          <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.amc.historyTitle")}</h2>
          <HistoryList tickets={amcHistory} t={t} />
        </Card>
      ) : null}

      <Card className="gap-3">
        <h2 className="px-1 text-sm font-semibold text-text">{t("customerApp.products.warrantyActive")}</h2>
        {warranty ? (
          <div className="space-y-1.5 px-1 text-xs">
            <div className="flex items-center justify-between">
              <StatusDot
                tone={warranty.expiry_date >= today ? "info" : "neutral"}
                label={warranty.expiry_date >= today ? t("customerApp.products.warrantyActive") : t("customerApp.products.warrantyExpired")}
              />
              <span className="text-text-muted">{t("customerApp.products.expiresOn", { date: warranty.expiry_date })}</span>
            </div>
            <p className="text-text-muted">{t("customerApp.products.purchasedOn", { date: warranty.start_date })}</p>
          </div>
        ) : (
          <p className="px-1 text-sm text-text-muted">{t("customerApp.amc.noWarranty")}</p>
        )}
        <div className="border-t border-border pt-2">
          <h3 className="px-1 pb-1 text-xs font-semibold text-text-muted">{t("customerApp.amc.warrantyHistoryTitle")}</h3>
          <HistoryList tickets={warrantyHistory} t={t} />
        </div>
      </Card>
    </div>
  )
}
