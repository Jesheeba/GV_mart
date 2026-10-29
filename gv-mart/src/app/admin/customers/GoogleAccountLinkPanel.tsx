import { useState } from "react"
import { useTranslation } from "react-i18next"
import { CheckCircle2, Link2, Loader2, TriangleAlert, Unlink } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAdminLinkCustomerGoogleAccount, useAdminUnlinkCustomerGoogleAccount } from "@/hooks/useCustomers"

const LINK_ERROR_KEYS = new Set([
  "customer_not_found",
  "test_customer",
  "already_linked",
  "invalid_email",
  "no_matching_signin",
  "ambiguous_signin",
  "signin_already_linked",
])
const UNLINK_ERROR_KEYS = new Set(["customer_not_found", "not_linked", "reason_required", "unlink_blocked_has_records"])

/**
 * Master-only stopgap while OTP linking (docs/spec-link-customer-login-phone-otp.md)
 * is parked — see 20261121100000_admin_link_customer_google_account.sql. Renders bare
 * (no outer Card), same convention as ExemptionWindowsPanel/FamilyMembersPanel.
 * CustomerDetailPage is responsible for only mounting this for profile.role === "master".
 */
export function GoogleAccountLinkPanel({ customerId, linked }: { customerId: string; linked: boolean }) {
  const { t } = useTranslation()
  const [email, setEmail] = useState("")
  const [reason, setReason] = useState("")
  const [done, setDone] = useState<"linked" | "unlinked" | null>(null)
  const link = useAdminLinkCustomerGoogleAccount(customerId)
  const unlink = useAdminUnlinkCustomerGoogleAccount(customerId)

  function errorMessage(error: unknown, knownKeys: Set<string>) {
    const code = (error as Error)?.message ?? ""
    const key = [...knownKeys].find((k) => code.includes(k))
    return key ? t(`customers.detail.googleLink.errors.${key}`) : t("common.actionFailed")
  }

  function submitLink() {
    setDone(null)
    link.mutate(email, {
      onSuccess: () => {
        setEmail("")
        setDone("linked")
      },
    })
  }

  function submitUnlink() {
    setDone(null)
    unlink.mutate(reason, {
      onSuccess: () => {
        setReason("")
        setDone("unlinked")
      },
    })
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <Link2 className="size-4 text-text-muted" />
        <h3 className="text-sm font-bold text-text">{t("customers.detail.googleLink.title")}</h3>
      </div>
      <p className="text-xs text-text-muted">{t("customers.detail.googleLink.hint")}</p>

      {done === "linked" ? (
        <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
          <CheckCircle2 className="size-4" /> {t("customers.detail.googleLink.linkSuccess")}
        </p>
      ) : null}
      {done === "unlinked" ? (
        <p className="flex items-center gap-1.5 rounded-xl bg-success/10 px-3.5 py-2.5 text-sm text-success">
          <CheckCircle2 className="size-4" /> {t("customers.detail.googleLink.unlinkSuccess")}
        </p>
      ) : null}

      {!linked ? (
        <div className="space-y-2">
          <div className="space-y-1">
            <Label htmlFor="google-link-email">{t("customers.detail.googleLink.emailLabel")}</Label>
            <Input
              id="google-link-email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder={t("customers.detail.googleLink.emailPlaceholder")}
            />
          </div>
          <Button type="button" size="sm" disabled={!email || link.isPending} onClick={submitLink}>
            {link.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Link2 className="size-3.5" />}
            {t("customers.detail.googleLink.linkAction")}
          </Button>
          {link.error ? (
            <p className="flex items-center gap-1.5 text-xs text-danger">
              <TriangleAlert className="size-3.5 shrink-0" /> {errorMessage(link.error, LINK_ERROR_KEYS)}
            </p>
          ) : null}
        </div>
      ) : (
        <div className="space-y-2">
          <p className="flex items-center gap-1.5 text-sm text-text">
            <CheckCircle2 className="size-4 text-success" /> {t("customers.detail.googleLink.alreadyLinked")}
          </p>
          <div className="space-y-1">
            <Label htmlFor="google-unlink-reason">{t("customers.detail.googleLink.unlinkReasonLabel")}</Label>
            <Input
              id="google-unlink-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder={t("customers.detail.googleLink.unlinkReasonPlaceholder")}
            />
          </div>
          <Button type="button" size="sm" variant="outline" className="text-danger hover:bg-danger/10" disabled={!reason.trim() || unlink.isPending} onClick={submitUnlink}>
            {unlink.isPending ? <Loader2 className="size-3.5 animate-spin" /> : <Unlink className="size-3.5" />}
            {t("customers.detail.googleLink.unlinkAction")}
          </Button>
          {unlink.error ? (
            <p className="flex items-center gap-1.5 text-xs text-danger">
              <TriangleAlert className="size-3.5 shrink-0" /> {errorMessage(unlink.error, UNLINK_ERROR_KEYS)}
            </p>
          ) : null}
        </div>
      )}
    </div>
  )
}
