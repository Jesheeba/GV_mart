import { useState } from "react"
import { useTranslation } from "react-i18next"
import { FlaskConical, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import { useToast } from "@/components/ui/toast-context"
import { useSettings, useUpdateSettings } from "@/hooks/useMasters"
import { useProfile } from "@/hooks/useProfile"
import { cn } from "@/lib/utils"

/** Pulls the bare 10-digit numbers out of free text (one per line, or comma / space separated; +91 and spaces tolerated). */
export function parseTestNumbers(text: string): { numbers: string[]; invalid: string[] } {
  const numbers: string[] = []
  const invalid: string[] = []
  for (const raw of text.split(/[\n,;]+/)) {
    const token = raw.trim()
    if (!token) continue
    const digits = token.replace(/\D/g, "")
    const bare = digits.length > 10 ? digits.slice(-10) : digits
    if (/^[6-9]\d{9}$/.test(bare) && (digits.length === 10 || (digits.length === 12 && digits.startsWith("91")))) {
      if (!numbers.includes(bare)) numbers.push(bare)
    } else {
      invalid.push(token)
    }
  }
  return { numbers, invalid }
}

/**
 * Master-only. WhatsApp test mode (settings.wa_test_mode_enabled, ships OFF): while ON, messages are sent only to the
 * numbers listed here; every other send is blocked and logged. Enforced where messages actually leave the system.
 */
export function WaTestModeSwitch() {
  const { t } = useTranslation()
  const { toast } = useToast()
  const { data: profile } = useProfile()
  const orgId = profile?.org_id
  const { data: settings, isLoading } = useSettings(orgId)
  const updateMut = useUpdateSettings(orgId)
  const [open, setOpen] = useState(false)
  const [text, setText] = useState("")
  const [enabled, setEnabled] = useState(false)

  if (profile?.role !== "master") return null
  if (isLoading || !settings) return <div className="h-9 w-36 animate-pulse rounded-full bg-surface-alt" />

  const on = settings.wa_test_mode_enabled
  const parsed = parseTestNumbers(text)
  const canSave = parsed.invalid.length === 0 && (!enabled || parsed.numbers.length > 0) && !updateMut.isPending

  function openDialog() {
    setText((settings?.wa_test_allowed_numbers ?? []).join("\n"))
    setEnabled(Boolean(settings?.wa_test_mode_enabled))
    setOpen(true)
  }

  function save() {
    if (!canSave) return
    updateMut.mutate(
      { wa_test_mode_enabled: enabled, wa_test_allowed_numbers: parsed.numbers },
      {
        onSuccess: () => {
          toast.success(t("automation.testMode.saved"))
          setOpen(false)
        },
        onError: (e) => toast.error(e instanceof Error && e.message ? e.message : t("automation.testMode.saveFailed")),
      }
    )
  }

  return (
    <>
      <Button
        size="sm"
        variant="outline"
        className={cn("border-transparent font-bold", on ? "bg-warning/15 text-warning hover:bg-warning/25" : "bg-surface-alt text-text-muted hover:bg-surface-alt/80")}
        onClick={openDialog}
      >
        <FlaskConical className="size-3.5" />
        {on ? t("automation.testMode.on") : t("automation.testMode.off")}
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-md space-y-3">
          <DialogTitle>{t("automation.testMode.title")}</DialogTitle>
          <DialogDescription>{t("automation.testMode.description")}</DialogDescription>

          <label className="flex items-center gap-2 text-sm font-medium text-text">
            <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} className="size-4" />
            {t("automation.testMode.enable")}
          </label>

          <div className="space-y-1.5">
            <Label htmlFor="wa-test-numbers">{t("automation.testMode.numbersLabel")}</Label>
            <textarea
              id="wa-test-numbers"
              rows={5}
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder={t("automation.testMode.numbersPlaceholder")}
              className="w-full rounded-xl border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30"
            />
            <p className="text-xs text-text-muted">{t("automation.testMode.numbersHint", { count: parsed.numbers.length })}</p>
            {parsed.invalid.length > 0 && <p className="text-xs text-danger">{t("automation.testMode.invalid", { list: parsed.invalid.join(", ") })}</p>}
            {enabled && parsed.numbers.length === 0 && <p className="text-xs text-danger">{t("automation.testMode.emptyWhileOn")}</p>}
          </div>

          <div className="flex justify-end gap-2">
            <Button variant="outline" onClick={() => setOpen(false)}>
              {t("common.cancel")}
            </Button>
            <Button onClick={save} disabled={!canSave}>
              {updateMut.isPending && <Loader2 className="size-4 animate-spin" />}
              {t("common.save")}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
