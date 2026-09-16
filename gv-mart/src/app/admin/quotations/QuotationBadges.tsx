import { useTranslation } from "react-i18next"
import { Tag } from "lucide-react"

/** Item 7 (2026-09-16) — quotations.lead_id already existed and was already
 * set correctly by create_quotation (see 20260715200000_quotation_from_
 * lead.sql); the only gap was that nothing displayed it. No new column
 * needed, this just surfaces the existing FK. */
export function QuotationOriginBadge({ leadName }: { leadName: string | null }) {
  const { t } = useTranslation()
  if (!leadName) {
    return <span className="text-[13px] font-medium text-text-muted">{t("quotations.origin.direct")}</span>
  }
  return (
    <span title={t("quotations.origin.fromLead", { name: leadName })} className="flex w-fit min-w-0 max-w-full items-center gap-1 rounded-full border border-border bg-surface-alt px-2.5 py-1 text-[11px] font-semibold text-text">
      <Tag className="size-3 shrink-0" />
      <span className="truncate">{t("quotations.origin.fromLead", { name: leadName })}</span>
    </span>
  )
}
