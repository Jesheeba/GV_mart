import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Printer, Trophy } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { DataTable, type DataTableColumn } from "@/components/shared/DataTable"
import { useProfile } from "@/hooks/useProfile"
import { useOrganization } from "@/hooks/useSales"
import { useTopCustomersReport } from "@/hooks/useReports"
import { defaultPeriodValue, periodToRange, type PeriodValue } from "@/services/reports"
import type { TopCustomerRow } from "@/services/reports"
import { ColumnPicker } from "@/components/shared/ColumnPicker"
import { useColumnPrefs } from "@/hooks/useColumnPrefs"
import { PeriodFilter } from "./PeriodFilter"
import { TOP_CUSTOMER_FIELDS, DEFAULT_TOP_CUSTOMER_FIELDS, type TopCustomerFieldKey } from "./topCustomerFields"

const TOP_CUSTOMER_KEYS = TOP_CUSTOMER_FIELDS.map((f) => f.key)
import { TopCustomersPrintSheet } from "./TopCustomersPrintSheet"

// Owner request: pick the top X customers by sales and print their details
// as a single sheet, with the admin choosing which fields go on the print
// — the field picker below drives TopCustomersPrintSheet's columns directly,
// so ticking/unticking a box changes what actually prints, live.
export function TopCustomersReportTab() {
  const { t } = useTranslation()
  const { data: profile } = useProfile()
  const { data: org } = useOrganization(profile?.org_id)
  const [period, setPeriod] = useState<PeriodValue>(defaultPeriodValue())
  const range = periodToRange(period)
  const [limitInput, setLimitInput] = useState("10")
  const limit = Math.max(1, Math.min(200, Number(limitInput) || 0))
  // One persisted field selection drives BOTH the on-screen table and the
  // printed sheet, so what you see is what prints.
  const fieldPrefs = useColumnPrefs<TopCustomerFieldKey>("topCustomers", TOP_CUSTOMER_KEYS, DEFAULT_TOP_CUSTOMER_FIELDS)
  const selectedFields = fieldPrefs.visible

  const { data, isLoading, isError, refetch } = useTopCustomersReport(profile?.org_id, range, limit)
  const rows = data ?? []

  const columns: DataTableColumn<TopCustomerRow>[] = TOP_CUSTOMER_FIELDS.filter((f) => fieldPrefs.isVisible(f.key)).map((f) => ({
    key: f.key,
    header: t(f.labelKey),
    render: (r: TopCustomerRow) => f.format(r),
  }))

  const rangeLabel = `${new Date(range.from).toLocaleDateString("en-IN")} – ${new Date(range.to).toLocaleDateString("en-IN")}`

  return (
    <div className="space-y-4">
      {/* Everything on-screen (filters, field picker, preview table) must be
          print:hidden — window.print() otherwise prints the whole tab as it
          sits on screen, not just the letterhead sheet below. Only
          TopCustomersPrintSheet (already `hidden ... print:block`) should
          render when printing, same convention as InvoicePage.tsx. */}
      <div className="space-y-4 print:hidden">
        <PeriodFilter value={period} onChange={setPeriod} />

        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <label className="block text-xs font-medium text-text-muted">{t("reports.topCustomers.topXLabel")}</label>
            <Input
              type="number"
              min={1}
              max={200}
              value={limitInput}
              onChange={(e) => setLimitInput(e.target.value)}
              className="h-9 w-28"
            />
          </div>
          <ColumnPicker
            options={TOP_CUSTOMER_FIELDS.map((f) => ({ key: f.key, label: t(f.labelKey) }))}
            visible={fieldPrefs.visible}
            onToggle={fieldPrefs.toggle}
            onReset={fieldPrefs.reset}
          />
          <Button type="button" className="ml-auto" onClick={() => window.print()} disabled={rows.length === 0}>
            <Printer className="size-4" />
            {t("reports.topCustomers.print")}
          </Button>
        </div>

        {isError ? (
          <p className="text-sm text-danger">
            {t("reports.loadFailed")}{" "}
            <button type="button" className="underline" onClick={() => refetch()}>
              {t("common.retry")}
            </button>
          </p>
        ) : (
          <div className="space-y-2">
            <p className="flex items-center gap-1.5 px-1 text-sm font-semibold text-text">
              <Trophy className="size-4" />
              {t("reports.topCustomers.title", { count: limit })}
            </p>
            <DataTable columns={columns} rows={rows} rowKey={(r) => r.customerId} loading={isLoading} emptyMessage={t("reports.empty")} />
          </div>
        )}
      </div>

      <TopCustomersPrintSheet
        orgName={org?.name ?? ""}
        orgAddress={org?.address ?? null}
        orgPhone={org?.phone ?? null}
        title={t("reports.topCustomers.printTitle", { count: limit })}
        rangeLabel={rangeLabel}
        rows={rows}
        fields={TOP_CUSTOMER_FIELDS.filter((f) => selectedFields.has(f.key)).map((f) => f.key)}
      />
    </div>
  )
}
