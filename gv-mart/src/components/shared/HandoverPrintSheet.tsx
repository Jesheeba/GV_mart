import { useTranslation } from "react-i18next"

// Same window.print() convention as InvoicePage.tsx / QuotationDetailPage.tsx
// (hidden on screen, `print:block` letterhead table) — no PDF library, no
// server round-trip. Shared between the admin handover/return history and
// the technician's own spare-receipt views so both sides print the identical
// layout. Deliberately spares-only (item.qty is qty_given) — a handover
// receipt isn't the place to also show a later, separately-recorded return.
export type HandoverPrintItem = { id: string; name: string; sku: string | null; qty: number }

export function HandoverPrintSheet({
  orgName,
  orgAddress,
  orgPhone,
  technicianName,
  date,
  status,
  items,
  adminSignUrl,
  techSignUrl,
}: {
  orgName: string
  orgAddress: string | null
  orgPhone: string | null
  technicianName: string
  date: string
  status: string
  items: HandoverPrintItem[]
  adminSignUrl: string | null
  techSignUrl: string | null
}) {
  const { t } = useTranslation()
  const CELL = "border border-[#444] p-2 align-top"

  return (
    <div className="hidden bg-white text-black print:block">
      <table className="w-full border-collapse">
        <tbody>
          <tr>
            <td className="p-2 align-top" />
            <td className="p-2 text-center align-top">
              <h2 className="m-1 text-xl font-bold">{orgName}</h2>
              {orgAddress ? <div>{orgAddress}</div> : null}
              <h3 className="m-1 text-lg font-bold">{t("technicians.spares.printTitle")}</h3>
            </td>
            <td className="p-2 text-right align-top">{orgPhone ?? ""}</td>
          </tr>
        </tbody>
      </table>

      <table className="mt-2 w-full border-collapse">
        <tbody>
          <tr>
            <td className={CELL}>
              <b>{t("technicians.spares.technician")}:</b> {technicianName}
            </td>
            <td className={CELL}>
              <b>{t("technicians.spares.date")}:</b> {new Date(date).toLocaleDateString("en-IN")}
            </td>
            <td className={CELL}>
              <b>{t("technicians.spares.status")}:</b> {t(`technicians.spares.statusValues.${status}`, { defaultValue: status })}
            </td>
          </tr>
        </tbody>
      </table>

      <table className="mt-2 w-full border-collapse">
        <thead>
          <tr>
            <th className={CELL}>{t("sales.invoice.sno")}</th>
            <th className={CELL}>{t("technicians.spares.spareColumn")}</th>
            <th className={CELL}>{t("technicians.spares.qty")}</th>
          </tr>
        </thead>
        <tbody>
          {items.length === 0 ? (
            <tr>
              <td colSpan={3} className={CELL}>
                {t("technician.spareHandover.noItems")}
              </td>
            </tr>
          ) : (
            items.map((item, i) => (
              <tr key={item.id}>
                <td className={CELL}>{i + 1}</td>
                <td className={CELL}>
                  {item.name}
                  {item.sku ? ` (${item.sku})` : ""}
                </td>
                <td className={`${CELL} text-right`}>{item.qty}</td>
              </tr>
            ))
          )}
        </tbody>
      </table>

      <table className="mt-2 w-full border-collapse">
        <tbody>
          <tr>
            <td className={`${CELL} w-1/2 text-center`}>
              <div>{t("technicians.spares.adminSign")}</div>
              {adminSignUrl ? (
                <img src={adminSignUrl} alt="" className="mx-auto h-20 object-contain" />
              ) : (
                <div className="h-20" />
              )}
            </td>
            <td className={`${CELL} w-1/2 text-center`}>
              <div>{t("technicians.spares.techSign")}</div>
              {techSignUrl ? (
                <img src={techSignUrl} alt="" className="mx-auto h-20 object-contain" />
              ) : (
                <div className="h-20" />
              )}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  )
}
