import { useTranslation } from "react-i18next"
import { Card } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import { useTechnicianTable } from "@/hooks/useTechnicianTable"
import { formatCurrency } from "@/lib/sale-calc"

/**
 * Technician table (item 15): revenue = invoice totals of COMPLETED jobs, absent days = Monday-Saturday working days minus
 * holidays minus days present or on leave, referral revenue counted forward only. The basis is stated on screen because the
 * "Revenue" column of the list above is the visit service charge, a different figure.
 */
export function TechnicianPerformanceTable({ from, to }: { from: string; to: string }) {
  const { t } = useTranslation()
  const q = useTechnicianTable(from, to)
  const rows = (q.data ?? []).filter((r) => r.is_active || r.jobs_completed > 0 || r.present_days > 0 || r.referral_total > 0)
  const num = (n: number) => n.toLocaleString("en-IN")

  return (
    <Card className="gap-3 px-5" data-testid="technician-performance-table">
      <div>
        <h2 className="text-base font-bold text-text">{t("technicians.performance.title")}</h2>
        <p className="text-xs text-text-muted">{t("technicians.performance.basis")}</p>
      </div>
      {q.isLoading ? (
        <Skeleton className="h-24 w-full" />
      ) : q.isError ? (
        <p className="text-sm text-danger">{q.error instanceof Error ? q.error.message : t("common.error")}</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-text-muted">{t("technicians.performance.empty")}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full min-w-[880px] text-left text-xs">
            <thead className="text-text-muted">
              <tr>
                <th className="py-1.5 pr-3 font-semibold">{t("technicians.performance.technician")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.jobs")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.revenue")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.avgCall")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.rating")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.workingDays")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.present")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.leave")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.absent")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.referralService")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.referralSales")}</th>
                <th className="py-1.5 pr-3 text-right font-semibold">{t("technicians.performance.referralAmc")}</th>
                <th className="py-1.5 text-right font-semibold">{t("technicians.performance.referralTotal")}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.technician_id} className="border-t border-border">
                  <td className="py-2 pr-3 font-medium text-text">
                    {r.name}
                    {!r.is_active ? <span className="ml-1.5 text-text-muted">({t("technicians.performance.inactive")})</span> : null}
                  </td>
                  <td className="gv-tnum py-2 pr-3 text-right">{num(r.jobs_completed)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right font-semibold text-text">{formatCurrency(r.revenue)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{r.avg_call_value != null ? formatCurrency(r.avg_call_value) : "—"}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{r.avg_rating != null ? `${r.avg_rating} (${r.rating_count})` : "—"}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{num(r.working_days)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{num(r.present_days)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{num(r.leave_days)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right font-semibold text-text">{num(r.absent_days)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{formatCurrency(r.referral_service)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{formatCurrency(r.referral_sales)}</td>
                  <td className="gv-tnum py-2 pr-3 text-right">{formatCurrency(r.referral_amc)}</td>
                  <td className="gv-tnum py-2 text-right font-semibold text-text">{formatCurrency(r.referral_total)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="text-[11px] text-text-muted">{t("technicians.performance.footnote")}</p>
    </Card>
  )
}
