import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Check, Copy, MessageCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"

/**
 * Owner decision (Technician Lifecycle Management, Phase 1): no email/SMS
 * service exists in this project, so a freshly generated password is shown
 * exactly once here — the admin copies it and shares it manually (WhatsApp
 * is the given example) rather than the app attempting to email/SMS it.
 * Shared by TechniciansListPage's Create flow and TechnicianDetailPage's
 * Reset Password action — same contract either way.
 */
export function PasswordRevealDialog({
  password,
  phone,
  onClose,
}: {
  password: string | null
  phone?: string | null
  onClose: () => void
}) {
  const { t } = useTranslation()
  const [copied, setCopied] = useState(false)

  async function copy() {
    if (!password) return
    await navigator.clipboard.writeText(password)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  const digits = phone?.replace(/\D/g, "") ?? ""
  const waNumber = digits.length === 10 ? `91${digits}` : digits
  const waHref =
    digits.length >= 10
      ? `https://wa.me/${waNumber}?text=${encodeURIComponent(t("technicians.list.whatsappShareText", { password }))}`
      : null

  // The triggering control isn't guaranteed to still be mounted when this
  // dialog closes (e.g. the Create Technician panel unmounts as soon as it
  // reveals the password), so base-ui's default trigger-restoration can
  // silently drop focus to <body>. Fall back to the page's <main> landmark,
  // which is always present, so focus lands somewhere meaningful instead.
  function focusStableFallback(): HTMLElement | null {
    const main = document.querySelector<HTMLElement>("main")
    if (!main) return null
    if (!main.hasAttribute("tabindex")) main.setAttribute("tabindex", "-1")
    return main
  }

  return (
    <Dialog open={!!password} onOpenChange={(open) => !open && onClose()}>
      <DialogContent showClose={false} finalFocus={() => focusStableFallback()}>
        <DialogTitle>{t("technicians.list.passwordDialogTitle")}</DialogTitle>
        <DialogDescription>{t("technicians.list.passwordDialogHint")}</DialogDescription>
        <div className="flex items-center gap-2 rounded-xl border border-border bg-surface-alt px-3.5 py-2.5">
          <code className="flex-1 select-all font-mono text-sm text-text">{password}</code>
          <Button type="button" size="sm" variant="outline" onClick={copy}>
            {copied ? <Check className="size-3.5 text-success" /> : <Copy className="size-3.5" />}
            {copied ? t("common.copied") : t("common.copy")}
          </Button>
        </div>
        {waHref ? (
          <Button
            nativeButton={false}
            render={<a href={waHref} target="_blank" rel="noreferrer" />}
            variant="outline"
            className="w-full"
          >
            <MessageCircle className="size-4" />
            {t("technicians.list.shareViaWhatsapp")}
          </Button>
        ) : null}
        <Button type="button" onClick={onClose} className="w-full">
          {t("common.done")}
        </Button>
      </DialogContent>
    </Dialog>
  )
}
