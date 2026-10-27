import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { PackageOpen } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { useMyStock, useMyTechnician } from "@/hooks/useTechnician"

/**
 * Requirement 3 (2026-11-14 gap fix) — "every technician has his own inventory (his held
 * stock), he sees only his own." The RLS (technician_stock_levels_select_own) already
 * scoped this correctly; this screen was the missing piece — before this, a technician had
 * no way to see their own running balance at all, only today's hand-over block and history.
 */
export function MySparesPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const technician = useMyTechnician()
  const stock = useMyStock(technician.data?.id)

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <div>
        <h1 className="text-xl font-bold text-text">{t("technician.myStock.title")}</h1>
        <p className="text-xs text-text-muted">{t("technician.myStock.subtitle")}</p>
      </div>

      {stock.isLoading ? (
        <Card className="items-center py-8 text-center">
          <p className="text-sm text-text-muted">{t("common.loading")}</p>
        </Card>
      ) : stock.isError ? (
        <FullPageError message={t("technician.myStock.loadFailed")} onRetry={() => stock.refetch()} retryLabel={t("common.retry")} />
      ) : !stock.data || stock.data.length === 0 ? (
        <Card className="items-center gap-2 py-8 text-center">
          <PackageOpen className="size-8 text-text-muted" />
          <p className="text-sm font-medium text-text">{t("technician.myStock.empty")}</p>
        </Card>
      ) : (
        <Card className="gap-0 divide-y divide-border p-0">
          {stock.data.map((row) => (
            <div key={row.id} className="flex items-center justify-between px-4 py-3">
              <div>
                <p className="text-sm font-medium text-text">{row.spares?.name ?? "—"}</p>
                <p className="text-xs text-text-muted">{row.spares?.sku ?? "—"}</p>
              </div>
              <span className="text-sm font-semibold text-text">{t("technician.myStock.qty", { qty: row.stock_qty })}</span>
            </div>
          ))}
        </Card>
      )}

      <Button type="button" variant="outline" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>
    </div>
  )
}
