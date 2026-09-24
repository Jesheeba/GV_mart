import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { useNavigate } from "react-router-dom"
import { History as HistoryIcon, Printer } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { StatusDot } from "@/components/shared/StatusDot"
import { FullPageError, FullPageLoader } from "@/components/shared/FullPageLoader"
import { HandoverPrintSheet } from "@/components/shared/HandoverPrintSheet"
import { useProfile } from "@/hooks/useProfile"
import { useOrganization } from "@/hooks/useSales"
import { useMyHandovers, useMyTechnician } from "@/hooks/useTechnician"

/** Simple find-and-print list — no per-handover detail route, since printing
 * is the only reason to reach a past handover from here (today's own view
 * already covers everything else: items, signatures, confirm). */
export function SpareHandoverHistoryPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const { data: profile } = useProfile()
  const { data: org } = useOrganization(profile?.org_id)
  const technician = useMyTechnician()
  const handovers = useMyHandovers(technician.data?.id)
  const [printingId, setPrintingId] = useState<string | null>(null)
  const printingHandover = (handovers.data ?? []).find((h) => h.id === printingId) ?? null

  useEffect(() => {
    if (!printingHandover) return
    const id = setTimeout(() => window.print(), 50)
    return () => clearTimeout(id)
  }, [printingHandover])

  if (technician.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (technician.isError || !technician.data) {
    return <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => technician.refetch()} retryLabel={t("common.retry")} />
  }

  return (
    <div className="space-y-4 pt-2">
      <h1 className="text-xl font-bold text-text print:hidden">{t("technician.spareHandover.history")}</h1>

      <div className="space-y-2.5 print:hidden">
        {handovers.isLoading ? (
          <Card className="items-center py-8 text-center">
            <p className="text-sm text-text-muted">{t("common.loading")}</p>
          </Card>
        ) : handovers.isError ? (
          <FullPageError message={t("technician.errors.loadFailed")} onRetry={() => handovers.refetch()} retryLabel={t("common.retry")} />
        ) : !handovers.data || handovers.data.length === 0 ? (
          <Card className="items-center gap-2 py-8 text-center">
            <HistoryIcon className="size-8 text-text-muted" />
            <p className="text-sm font-medium text-text">{t("technician.spareHandover.emptyTitle")}</p>
          </Card>
        ) : (
          handovers.data.map((h) => (
            <Card key={h.id} className="gap-2">
              <div className="flex items-start justify-between gap-2 px-1">
                <div className="min-w-0">
                  <p className="text-sm font-semibold text-text">{new Date(h.date).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" })}</p>
                  <p className="truncate text-xs text-text-muted">
                    {h.spare_handover_items.length === 0
                      ? t("technician.spareHandover.noItems")
                      : h.spare_handover_items.map((i) => `${i.spares?.name ?? "?"} ×${i.qty_given}`).join(", ")}
                  </p>
                </div>
                <StatusDot tone={h.status === "confirmed" ? "success" : "warning"} label={t(`technicians.spares.statusValues.${h.status}`)} />
              </div>
              <div className="flex justify-end px-1">
                <Button size="xs" variant="outline" onClick={() => setPrintingId(h.id)}>
                  <Printer className="size-3.5" />
                  {t("technicians.spares.print")}
                </Button>
              </div>
            </Card>
          ))
        )}
      </div>

      <Button type="button" variant="outline" className="print:hidden" onClick={() => navigate(-1)}>
        {t("common.back")}
      </Button>

      {printingHandover ? (
        <HandoverPrintSheet
          orgName={org?.name ?? t("common.appName")}
          orgAddress={org?.address ?? null}
          orgPhone={org?.phone ?? null}
          technicianName={profile?.full_name ?? "—"}
          date={printingHandover.date}
          status={printingHandover.status}
          items={printingHandover.spare_handover_items.map((i) => ({
            id: i.id,
            name: i.spares?.name ?? "?",
            sku: i.spares?.sku ?? null,
            qty: i.qty_given,
          }))}
          adminSignUrl={printingHandover.admin_sign_url}
          techSignUrl={printingHandover.tech_sign_url}
        />
      ) : null}
    </div>
  )
}
