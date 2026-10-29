import { useTranslation } from "react-i18next"
import { ShieldCheck } from "lucide-react"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { signOut } from "@/services/auth"

/**
 * Shown after a first-time Google sign-in when the auth user has no
 * `profiles` row — admin-created customers (create_customer_with_details)
 * never get one until linked.
 *
 * Interim notice (2026-10-29): link_customer_google_account's EXECUTE grant
 * was revoked (20261021100000, account-takeover fix — see
 * gv_mart_link_customer_account_takeover_2026_10_14 in project memory) and
 * no replacement has shipped yet, so every linking attempt would fail with
 * the exact same error no matter how many times it's retried. Rather than
 * show a mobile-number form and a "try again" button for a flow that cannot
 * currently succeed, this is a static notice with no retry affordance at
 * all — replaced once the OTP-based linking flow ships.
 */
export function GoogleLinkAccountCard() {
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
        <p className="mt-3 rounded-xl bg-surface-alt px-3.5 py-3 text-sm text-text">{t("auth.linkAccountUnavailable")}</p>

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
