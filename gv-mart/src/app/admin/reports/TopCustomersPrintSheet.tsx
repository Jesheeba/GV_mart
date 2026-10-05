import { useTranslation } from "react-i18next"
import type { TopCustomerRow } from "@/services/reports"
import { TOP_CUSTOMER_FIELDS, type TopCustomerFieldKey } from "./topCustomerFields"

// Same window.print() convention as HandoverPrintSheet.tsx / InvoicePage.tsx
// (hidden on screen, `print:block` letterhead table). `fields` is the set of
// columns the admin picked in the tab's checklist — the sheet renders
// exactly those columns, in TOP_CUSTOMER_FIELDS order, so the printed
// one-pager reflects whatever they chose without any separate template.
export function TopCustomersPrintSheet({
  orgName,
  orgAddress,
  orgPhone,
  title,
  rangeLabel,
  rows,
  fields,
}: {
  orgName: string
  orgAddress: string | null
  orgPhone: string | null
  title: string
  rangeLabel: string
  rows: TopCustomerRow[]
  fields: TopCustomerFieldKey[]
}) {
  const { t } = useTranslation()
  const CELL = "border border-[#444] p-2 align-top"
  const activeFields = TOP_CUSTOMER_FIELDS.filter((f) => fields.includes(f.key))

  return (
    <div className="hidden bg-white text-black print:block">
      <table className="w-full border-collapse">
        <tbody>
          <tr>
            <td className="p-2 text-center align-top">
              <h2 className="m-1 text-xl font-bold">{orgName}</h2>
              {orgAddress ? <div>{orgAddress}</div> : null}
              {orgPhone ? <div>{orgPhone}</div> : null}
              <h3 className="m-1 text-lg font-bold">{title}</h3>
              <div className="text-sm">{rangeLabel}</div>
            </td>
          </tr>
        </tbody>
      </table>

      <table className="mt-2 w-full border-collapse">
        <thead>
          <tr>
            {activeFields.map((f) => (
              <th key={f.key} className={CELL}>
                {t(f.labelKey)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={activeFields.length || 1} className={CELL}>
                {t("reports.empty")}
              </td>
            </tr>
          ) : (
            rows.map((row) => (
              <tr key={row.customerId}>
                {activeFields.map((f) => (
                  <td key={f.key} className={`${CELL}${f.align === "right" ? " text-right" : ""}`}>
                    {f.format(row)}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )
}
