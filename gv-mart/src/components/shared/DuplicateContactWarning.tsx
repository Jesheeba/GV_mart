import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { TriangleAlert } from "lucide-react"
import type { DuplicateContactMatch } from "@/lib/duplicateContactWarning"

/**
 * Urgent item (2026-11-02): non-blocking "existing record(s) found" banner,
 * fed by useDuplicateContactWarning (find_duplicate_contacts RPC — NOT
 * applied yet, see 20261204130000_duplicate_contact_warning_rpc.sql). Shared
 * by CustomerFormPage (Create Customer) and NewLeadForm (Create Lead) so the
 * two flows show the exact same banner rather than two near-identical ones.
 *
 * Never a hard block — same "informational, surfaced only once there's a
 * real conflict, never pre-emptive" shape as assign_ticket_technician's
 * p_force override (TicketDetailPage.tsx's force-reassign button). Save
 * stays clickable; `confirmed` only gates it via canSubmitWithWarning in the
 * caller, and the explicit tick here is what sets `confirmed`.
 */
export function DuplicateContactWarning({
  matches,
  isLoading,
  confirmed,
  onConfirmedChange,
}: {
  matches: DuplicateContactMatch[] | undefined
  isLoading: boolean
  confirmed: boolean
  onConfirmedChange: (next: boolean) => void
}) {
  const { t } = useTranslation()
  if (isLoading || !matches || matches.length === 0) return null

  return (
    <div className="space-y-2 rounded-xl border border-warning/40 bg-warning/10 px-3.5 py-2.5 text-sm text-text" role="status">
      <div className="flex items-start gap-2.5">
        <TriangleAlert className="mt-0.5 size-4 shrink-0 text-warning" />
        <span className="font-medium">{t("customers.duplicateContactWarning.title", { count: matches.length })}</span>
      </div>
      <ul className="space-y-1.5 pl-6.5">
        {matches.map((m) => (
          <li key={`${m.source}-${m.id}`} className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-text-muted">
            <span className="text-text">{m.name}</span>
            <span>
              {m.source === "customer"
                ? t("customers.duplicateContactWarning.sourceCustomer")
                : t("customers.duplicateContactWarning.sourceLead")}
            </span>
            {m.mobile ? <span>{m.mobile}</span> : null}
            {m.source === "customer" && (m.ticket_count > 0 || m.invoice_count > 0) ? (
              <span>{t("customers.duplicateContactWarning.activity", { tickets: m.ticket_count, invoices: m.invoice_count })}</span>
            ) : null}
            <Link
              to={m.source === "customer" ? `/admin/customers/${m.id}` : `/admin/leads/${m.id}`}
              target="_blank"
              rel="noopener noreferrer"
              className="font-semibold text-accent hover:underline"
            >
              {t("customers.duplicateContactWarning.openExisting")}
            </Link>
          </li>
        ))}
      </ul>
      <label className="flex items-center gap-2 pt-1 text-xs font-medium">
        <input type="checkbox" checked={confirmed} onChange={(e) => onConfirmedChange(e.target.checked)} className="size-3.5 accent-warning" />
        {t("customers.duplicateContactWarning.createAnyway")}
      </label>
    </div>
  )
}
