import { useTranslation } from "react-i18next"
import { ShieldAlert } from "lucide-react"
import { useMyCustomerId, useMyCustomerRecord } from "@/hooks/useCustomerApp"

/**
 * Item 5(c). Shown app-wide (shell-mounted, same pattern as OtpAlertBanner/
 * TechnicianAssignedBanner) when the signed-in customer's own record has
 * `needs_review = true` -- set server-side by customer_auto_onboard() or the
 * phone-OTP merge-on-verify path when a Google/phone sign-in matched more
 * than one existing record, or matched one already linked elsewhere, and
 * the system deliberately did not guess which account is theirs.
 *
 * GUARDRAIL (owner, 2026-11-03): this message must say ONLY that the shop is
 * reviewing the account and will contact them -- it must NEVER show the
 * names, mobiles or emails of the other matching record(s), or even how many
 * matched. `needs_review_reason` (an internal, ops-oriented sentence written
 * by the SQL functions above) is never read or rendered here for that same
 * reason. No dismiss button: this persists until a master resolves it
 * server-side (needs_review flips back to false), the same "ground truth is
 * the data, not local state" shape as TechnicianAssignedBanner.
 *
 * Also per that guardrail: nothing here ever contacts the customer outside
 * the app (no WhatsApp/SMS/email) -- this is purely an in-app, pull-based
 * banner driven by the customer's own already-fetched record.
 */
export function NeedsReviewBanner() {
  const { t } = useTranslation()
  const { customerId } = useMyCustomerId()
  const { data: record } = useMyCustomerRecord(customerId)

  if (!record?.needs_review) return null

  return (
    <div
      role="status"
      aria-live="polite"
      className="mx-4 mb-3 flex items-center gap-2.5 rounded-xl border border-accent/30 bg-accent-soft pl-3.5 pr-2 py-2.5 lg:mx-25"
    >
      <ShieldAlert className="size-4 shrink-0 text-accent" />
      <p className="flex-1 text-xs font-medium text-text">{t("customerApp.needsReviewAlert.message")}</p>
    </div>
  )
}
