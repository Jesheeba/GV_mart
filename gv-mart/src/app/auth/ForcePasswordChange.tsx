import { useState } from "react"
import { useTranslation } from "react-i18next"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useAuth } from "@/hooks/useAuth"
import { changeOwnPasswordAndAcknowledge, signOut } from "@/services/auth"

const MIN_LENGTH = 10

/**
 * Shown in place of the app while profiles.must_change_password is true (a new account, or a password an administrator
 * reset). Nothing else renders until the person has chosen their own password; the database clears the flag through
 * acknowledge_password_change(), never the client directly.
 */
export function ForcePasswordChange() {
  const { t } = useTranslation()
  const qc = useQueryClient()
  const { session } = useAuth()
  const [password, setPassword] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const tooShort = new TextEncoder().encode(password).length < MIN_LENGTH
  const mismatch = confirm.length > 0 && confirm !== password
  const canSubmit = !tooShort && !mismatch && confirm.length > 0 && !busy

  async function submit() {
    if (!canSubmit) return
    setBusy(true)
    setError(null)
    try {
      await changeOwnPasswordAndAcknowledge(password)
      await qc.invalidateQueries({ queryKey: ["profile", session?.user.id] })
    } catch {
      setError(t("auth.forcePassword.failed"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex min-h-dvh items-center justify-center bg-bg px-4">
      <Card className="w-full max-w-sm gap-4 p-6">
        <div className="space-y-1">
          <h1 className="text-lg font-bold text-text">{t("auth.forcePassword.title")}</h1>
          <p className="text-sm text-text-muted">{t("auth.forcePassword.body")}</p>
        </div>
        <form
          className="space-y-3"
          onSubmit={(e) => {
            e.preventDefault()
            void submit()
          }}
        >
          <div className="space-y-1">
            <Label htmlFor="force-new-password" className="block text-xs font-medium text-text-muted">
              {t("auth.forcePassword.newPassword")}
            </Label>
            <Input id="force-new-password" type="password" autoComplete="new-password" value={password} maxLength={72} onChange={(e) => setPassword(e.target.value)} />
            {password.length > 0 && tooShort ? <p className="text-xs text-danger">{t("auth.forcePassword.tooShort")}</p> : null}
          </div>
          <div className="space-y-1">
            <Label htmlFor="force-confirm-password" className="block text-xs font-medium text-text-muted">
              {t("auth.forcePassword.confirmPassword")}
            </Label>
            <Input id="force-confirm-password" type="password" autoComplete="new-password" value={confirm} maxLength={72} onChange={(e) => setConfirm(e.target.value)} />
            {mismatch ? <p className="text-xs text-danger">{t("auth.forcePassword.mismatch")}</p> : null}
          </div>
          {error ? <p className="text-sm text-danger">{error}</p> : null}
          <div className="flex items-center justify-between gap-2">
            <Button type="button" variant="ghost" onClick={() => void signOut()}>
              {t("auth.forcePassword.signOut")}
            </Button>
            <Button type="submit" disabled={!canSubmit}>
              {busy ? <Loader2 className="size-3.5 animate-spin" /> : null}
              {busy ? t("auth.forcePassword.saving") : t("auth.forcePassword.submit")}
            </Button>
          </div>
        </form>
      </Card>
    </div>
  )
}
