import { useTranslation } from "react-i18next"
import { ShieldCheck } from "lucide-react"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { signOut } from "@/services/auth"

/**
 * Shown after a first-time Google sign-in when customer_auto_onboard()
 * (20261130100001_customer_auto_onboard_rpc.sql, called from
 * CustomerAutoOnboardGate) couldn't complete automatically:
 *   - `reason="staff_account"` — the signed-in Google account belongs to a
 *     staff/technician/master profile. Customer self-service never applies
 *     to staff; they sign in with their password instead.
 *   - `reason="error"` — any other RPC failure (network, unexpected server
 *     error). Generic, with a sign-out-and-retry affordance.
 *
 * Until 2026-11-30 this was a permanent dead end for EVERY first-time
 * Google sign-in (link_customer_google_account's EXECUTE grant was revoked
 * 20261021100000, account-takeover fix, with no replacement live yet) — see
 * gv_mart_link_customer_account_takeover_2026_10_14 in project memory for
 * that history. customer_auto_onboard() now handles the success path
 * entirely on its own; this card only ever renders for the two refusal
 * cases above.
 */
export function GoogleLinkAccountCard({ reason }: { reason: "staff_account" | "error" }) {
  const { t } = useTranslation()

  return (
    <div className="flex min-h-screen items-center justify-center bg-bg px-6 py-10">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center justify-between">
          <img src="/logo-icon.svg" alt="GV Mart" className="size-11" />
          <LanguageToggle />
        </div>

        <p className="text-xs font-semibold uppercase tracking-wide text-accent">{t("auth.signInEyebrow")}</p>
        <h2 className="mt-1 text-2xl font-bold text-text">{t("auth.linkAccountTitle")}</h2>
        <p className="mt-3 rounded-xl bg-surface-alt px-3.5 py-3 text-sm text-text">
          {t(reason === "staff_account" ? "auth.staffAccountNotice" : "auth.linkAccountUnavailable")}
        </p>

        <button
          type="button"
          className="mt-4 w-full text-center text-xs font-medium text-text-muted hover:text-text hover:underline"
          onClick={() => signOut()}
        >
          {t("auth.useDifferentAccount")}
        </button>

        <p className="mt-6 flex items-start gap-2 text-xs text-text-muted">
          <ShieldCheck className="mt-0.5 size-3.5 shrink-0" />
          {t("auth.trustNote")}
        </p>
      </div>
    </div>
  )
}
