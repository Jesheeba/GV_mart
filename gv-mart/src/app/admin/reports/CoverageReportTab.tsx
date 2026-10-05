import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CalendarClock, ShieldCheck, Wrench, Hammer } from "lucide-react"
import { KpiCard } from "@/components/shared/KpiCard"
import { ColumnPicker } from "@/components/shared/ColumnPicker"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useColumnPrefs } from "@/hooks/useColumnPrefs"
import { useProfile } from "@/hooks/useProfile"
import { useCoverageReport } from "@/hooks/useReports"
import { defaultPeriodValue, downloadCsv, periodToRange, toCsv, type PeriodValue } from "@/services/reports"
import type { CoverageMonth } from "@/services/reportsInsights"
import { formatCurrency } from "@/lib/sale-calc"
import { PeriodFilter } from "./PeriodFilter"

const COVERAGE_COLUMNS = ["warrantyVisits", "warrantyActive", "amcVisits", "amcActive", "amcValue", "rentVisits", "rentActive", "rentValue"] as const
type CoverageColumn = (typeof COVERAGE_COLUMNS)[number]

function monthLabel(month: string) {
  const [y, m] = month.split("-").map(Number)
  return new Date(y, m - 1, 1).toLocaleDateString("en-IN", { month: "short", year: "numeric" })
}

/** Phase 2 Part D + installation rates. Warranty/AMC/Rent visit counts and
 * plan values per month, all read from existing contract + ticket tables. */
export function CoverageReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const { data, isLoading, isError, refetch } = useCoverageReport(profile?.org_id, range)
  const cols = useColumnPrefs<CoverageColumn>("coverage", COVERAGE_COLUMNS, COVERAGE_COLUMNS)

  const months = data?.months ?? []
  const sum = (f: (m: CoverageMonth) => number) => months.reduce((s, m) => s + f(m), 0)
  const inst = data?.installation

  const defs: Record<CoverageColumn, DataTableColumn<CoverageMonth>> = {
    warrantyVisits: { key: "wv", header: t("reports.coverage.warrantyVisits"), render: (r) => r.warranty.visits },
    warrantyActive: { key: "wa", header: t("reports.coverage.warrantyActive"), render: (r) => r.warranty.active },
    amcVisits: { key: "av", header: t("reports.coverage.amcVisits"), render: (r) => r.amc.visits },
    amcActive: { key: "aa", header: t("reports.coverage.amcActive"), render: (r) => r.amc.active },
    amcValue: { key: "ap", header: t("reports.coverage.amcValue"), render: (r) => formatCurrency(r.amc.planValue) },
    rentVisits: { key: "rv", header: t("reports.coverage.rentVisits"), render: (r) => r.rental.visits },
    rentActive: { key: "ra", header: t("reports.coverage.rentActive"), render: (r) => r.rental.active },
    rentValue: { key: "rp", header: t("reports.coverage.rentValue"), render: (r) => formatCurrency(r.rental.planValue) },
  }
  const columns: DataTableColumn<CoverageMonth>[] = [
    { key: "month", header: t("reports.coverage.month"), render: (r) => monthLabel(r.month) },
    ...COVERAGE_COLUMNS.filter((c) => cols.isVisible(c)).map((c) => defs[c]),
  ]

  function handleExport() {
    const csv = toCsv(
      [t("reports.coverage.month"), ...COVERAGE_COLUMNS.map((c) => t(`reports.coverage.${c}`))],
      months.map((m) => [m.month, m.warranty.visits, m.warranty.active, m.amc.visits, m.amc.active, m.amc.planValue, m.rental.visits, m.rental.active, m.rental.planValue])
    )
    downloadCsv(`coverage-report_${range.from}_${range.to}.csv`, csv)
  }

  const fmt = (n: number | null) => (n == null ? "—" : String(n))

  return (
    <div className="space-y-4">
      <PeriodFilter value={period} onChange={setPeriod} onExport={handleExport} />

      {isError ? (
        <p className="text-sm text-danger">
          {t("reports.loadFailed")}{" "}
          <button type="button" className="underline" onClick={() => refetch()}>
            {t("common.retry")}
          </button>
        </p>
      ) : null}

      <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <KpiCard
          label={t("reports.coverage.warranty")}
          value={isLoading ? "—" : `${sum((m) => m.warranty.visits)} ${t("reports.coverage.visitsUnit")}`}
          subValue={t("reports.coverage.warrantyNoPrice")}
          icon={<Wrench className="size-4" />}
          loading={isLoading}
        />
        <KpiCard
          label={t("reports.coverage.amc")}
          value={isLoading ? "—" : `${sum((m) => m.amc.visits)} ${t("reports.coverage.visitsUnit")}`}
          subValue={`${t("reports.coverage.planValueTotal")}: ${formatCurrency(sum((m) => m.amc.planValue))}`}
          icon={<ShieldCheck className="size-4" />}
          loading={isLoading}
        />
        <KpiCard
          label={t("reports.coverage.rent")}
          value={isLoading ? "—" : `${sum((m) => m.rental.visits)} ${t("reports.coverage.visitsUnit")}`}
          subValue={`${t("reports.coverage.planValueTotal")}: ${formatCurrency(sum((m) => m.rental.planValue))}`}
          icon={<CalendarClock className="size-4" />}
          loading={isLoading}
        />
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between gap-2 px-1">
          <p className="text-sm font-semibold text-text">{t("reports.coverage.byMonth")}</p>
          <ColumnPicker
            options={COVERAGE_COLUMNS.map((c) => ({ key: c, label: t(`reports.coverage.${c}`) }))}
            visible={cols.visible}
            onToggle={cols.toggle}
            onReset={cols.reset}
          />
        </div>
        <DataTable columns={columns} rows={months} rowKey={(r) => r.month} loading={isLoading} emptyMessage={t("reports.empty")} />
        <p className="px-1 text-[11px] text-text-muted">{t("reports.coverage.note")}</p>
        {data?.truncated ? <p className="px-1 text-[11px] text-warning">{t("reports.coverage.truncated")}</p> : null}
      </div>

      <div className="space-y-2">
        <p className="px-1 text-sm font-semibold text-text">{t("reports.coverage.installRateTitle")}</p>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <KpiCard
            label={t("reports.coverage.installPerTech")}
            value={isLoading ? "—" : fmt(inst?.perTechnicianPerMonth ?? null)}
            subValue={inst ? t("reports.coverage.installPerTechFormula", { installs: inst.installs, techs: inst.technicianCount, months: inst.monthsCount }) : undefined}
            icon={<Hammer className="size-4" />}
            loading={isLoading}
          />
          <KpiCard
            label={t("reports.coverage.installPerProduct")}
            value={isLoading ? "—" : fmt(inst?.perProductSold ?? null)}
            subValue={inst ? t("reports.coverage.installPerProductFormula", { installs: inst.installs, sold: inst.unitsSold }) : undefined}
            icon={<Hammer className="size-4" />}
            loading={isLoading}
          />
          <KpiCard
            label={t("reports.coverage.installPerVisit")}
            value={isLoading ? "—" : fmt(inst?.perVisit ?? null)}
            subValue={inst ? t("reports.coverage.installPerVisitFormula", { installs: inst.installs, visits: inst.visits }) : undefined}
            icon={<Hammer className="size-4" />}
            loading={isLoading}
          />
        </div>
        {inst && inst.byTechnician.length > 0 ? (
          <DataTable
            columns={[
              { key: "n", header: t("reports.salesService.technician"), render: (r) => r.name },
              { key: "i", header: t("reports.performance.installations"), render: (r) => r.installs },
              { key: "m", header: t("reports.coverage.installPerMonth"), render: (r) => r.perMonth },
            ]}
            rows={inst.byTechnician}
            rowKey={(r) => r.technicianId}
          />
        ) : null}
      </div>
    </div>
  )
}
