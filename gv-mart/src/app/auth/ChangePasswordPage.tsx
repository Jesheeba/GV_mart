import { useState } from "react"
import { useTranslation } from "react-i18next"
import { Navigate, useNavigate } from "react-router-dom"
import { useQueryClient } from "@tanstack/react-query"
import { Loader2, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { useProfile } from "@/hooks/useProfile"
import { useMustChangePassword } from "@/hooks/useMustChangePassword"
import { roleHomePath } from "@/lib/roles"
import { supabase } from "@/lib/supabase"
import { signOut } from "@/services/auth"

const MIN_LENGTH = 10

/**
 * First-login gate: a new staff account (or one whose password a master just reset) must choose its own password before it
 * can use the app. The database clears the flag only when the password hash has actually changed, so this screen cannot be
 * skipped by calling the function without changing the password.
 */
export function ChangePasswordPage() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { data: profile, isLoading } = useProfile()
  const mustChange = useMustChangePassword()
  const [password, setPassword] = useState("")
  const [confirm, setConfirm] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (isLoading || mustChange.isLoading) return <FullPageLoader label={t("common.loading")} />
  if (!profile) return <Navigate to="/login" replace />
  if (mustChange.data !== true) return <Navigate to={roleHomePath(profile.role)} replace />

  const tooShort = password.length > 0 && new TextEncoder().encode(password).length < MIN_LENGTH
  const mismatch = confirm.length > 0 && confirm !== password
  const canSubmit = new TextEncoder().encode(password).length >= MIN_LENGTH && password === confirm && !busy

  async function submit() {
    if (!canSubmit || !profile) return
    setBusy(true)
    setError(null)
    try {
      const { error: upErr } = await supabase.auth.updateUser({ password })
      if (upErr) throw upErr
      const { error: rpcErr } = await supabase.rpc("complete_forced_password_change")
      if (rpcErr) throw rpcErr
      await qc.invalidateQueries({ queryKey: ["profile"] })
      navigate(roleHomePath(profile.role), { replace: true })
    } catch (e) {
      setError(e instanceof Error && e.message ? e.message : t("auth.forcedPassword.failed"))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-4 px-4 py-8">
      <div className="flex items-center gap-2 text-text">
        <ShieldCheck className="size-5" />
        <h1 className="text-lg font-bold">{t("auth.forcedPassword.title")}</h1>
      </div>
      <p className="text-sm text-text-muted">{t("auth.forcedPassword.hint")}</p>
      <form
        className="space-y-3"
        onSubmit={(e) => {
          e.preventDefault()
          void submit()
        }}
      >
        <div className="space-y-1">
          <Label htmlFor="new-password">{t("auth.forcedPassword.newPassword")}</Label>
          <Input id="new-password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          {tooShort ? <p className="text-xs text-danger">{t("auth.forcedPassword.tooShort", { count: MIN_LENGTH })}</p> : null}
        </div>
        <div className="space-y-1">
          <Label htmlFor="confirm-password">{t("auth.forcedPassword.confirm")}</Label>
          <Input id="confirm-password" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
          {mismatch ? <p className="text-xs text-danger">{t("auth.forcedPassword.mismatch")}</p> : null}
        </div>
        {error ? <p className="rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">{error}</p> : null}
        <Button type="submit" className="h-11 w-full" disabled={!canSubmit}>
          {busy ? <Loader2 className="size-4 animate-spin" /> : t("auth.forcedPassword.submit")}
        </Button>
      </form>
      <button type="button" className="text-xs text-text-muted underline" onClick={() => void signOut()}>
        {t("auth.forcedPassword.signOut")}
      </button>
    </main>
  )
}
