import { useTranslation } from "react-i18next"
import { useActiveReferrers } from "@/hooks/useReferrals"

/**
 * Referral incentives — "Referred by" picker shared by the customer form
 * (People step) and the lead form. Plain native <select>, matching this
 * codebase's existing idiom for fixed-list pickers (see
 * PreferredLanguageSelect.tsx / NewComplaintPage.tsx's technician select) —
 * not shadcn/ui.
 *
 * Backed by `useActiveReferrers` -> `list_active_referrers` RPC (live since
 * referral incentives package 2). The field is optional everywhere it's
 * used, so an empty list (e.g. no active technicians/staff yet) is harmless.
 *
 * Groups technician/staff kinds into two <optgroup>s only when both kinds
 * are present in the result — a flat list otherwise (single-group org, or
 * while the RPC doesn't exist yet and returns nothing).
 */
export function ReferrerPicker({
  orgId,
  value,
  onChange,
  id,
  label,
  disabled,
}: {
  orgId: string | undefined
  value: string
  onChange: (next: string) => void
  id?: string
  label: string
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const { data: referrers } = useActiveReferrers(orgId)
  const technicians = (referrers ?? []).filter((r) => r.kind === "technician")
  const staff = (referrers ?? []).filter((r) => r.kind === "staff")
  const hasBothKinds = technicians.length > 0 && staff.length > 0

  return (
    <div className="space-y-1">
      <label htmlFor={id} className="block text-xs font-medium text-text-muted">
        {label}
      </label>
      <select
        id={id}
        disabled={disabled}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="h-10 w-full rounded-xl border border-border bg-surface px-3 text-sm text-text outline-none sm:max-w-xs"
      >
        <option value="">{t("common.none")}</option>
        {hasBothKinds ? (
          <>
            {/* Reuses existing keys (roles.technician, reports.staff) rather than adding new
                i18n keys beyond the two this stream was scoped to (customers.form.referredBy,
                leads.new.referredBy) — see hooks/useReferrals.ts header. */}
            <optgroup label={t("roles.technician")}>
              {technicians.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.full_name}
                </option>
              ))}
            </optgroup>
            <optgroup label={t("reports.staff")}>
              {staff.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.full_name}
                </option>
              ))}
            </optgroup>
          </>
        ) : (
          [...technicians, ...staff].map((r) => (
            <option key={r.id} value={r.id}>
              {r.full_name}
            </option>
          ))
        )}
      </select>
    </div>
  )
}
