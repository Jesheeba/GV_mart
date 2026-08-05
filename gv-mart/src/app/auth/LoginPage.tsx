import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useTranslation } from "react-i18next"
import { Navigate } from "react-router-dom"
import { useMutation } from "@tanstack/react-query"
import { Eye, EyeOff, Lock, Mail, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { FullPageLoader } from "@/components/shared/FullPageLoader"
import { GoogleLinkAccountCard } from "@/app/auth/GoogleLinkAccountCard"
import { useAuth } from "@/hooks/useAuth"
import { useProfile } from "@/hooks/useProfile"
import { roleHomePath } from "@/lib/roles"
import { signInWithGoogle, signInWithPassword } from "@/services/auth"
import { supabase } from "@/lib/supabase"

const loginSchema = z.object({
  email: z.string().min(1).email(),
  password: z.string().min(1),
})
type LoginFormValues = z.infer<typeof loginSchema>

/** PostgREST's ".single() found 0 rows" code — the signal that this auth user (e.g. a first-time Google sign-in) has no `profiles` row yet. */
const NO_PROFILE_ROW_CODE = "PGRST116"

/** Google's official multi-color "G" mark — lucide-react deliberately excludes brand logos. */
function GoogleLogo({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden="true">
      <path
        fill="#4285F4"
        d="M23.52 12.27c0-.85-.08-1.67-.22-2.45H12v4.64h6.47a5.54 5.54 0 0 1-2.4 3.63v3h3.88c2.27-2.09 3.57-5.17 3.57-8.82Z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.96-1.07 7.95-2.91l-3.88-3c-1.08.72-2.45 1.15-4.07 1.15-3.13 0-5.78-2.11-6.73-4.96H1.26v3.09A12 12 0 0 0 12 24Z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.28A7.2 7.2 0 0 1 4.89 12c0-.79.14-1.56.38-2.28V6.63H1.26A12 12 0 0 0 0 12c0 1.94.46 3.77 1.26 5.37l4.01-3.09Z"
      />
      <path
        fill="#EA4335"
        d="M12 4.77c1.76 0 3.35.61 4.6 1.8l3.44-3.44C17.95 1.19 15.24 0 12 0A12 12 0 0 0 1.26 6.63l4.01 3.09C6.22 6.88 8.87 4.77 12 4.77Z"
      />
    </svg>
  )
}

const DEMO_LOGINS = [
  { role: "master", email: "master@gvmart.test" },
  { role: "operation_admin", email: "operation_admin@gvmart.test" },
  { role: "sales_admin", email: "sales_admin@gvmart.test" },
  { role: "technician", email: "technician@gvmart.test" },
  { role: "customer", email: "customer@gvmart.test" },
] as const

export function LoginPage() {
  const { t } = useTranslation()
  const { session, loading: sessionLoading } = useAuth()
  const { data: profile, isLoading: profileLoading, error: profileError } = useProfile()
  const [showPassword, setShowPassword] = useState(false)
  const [showDemoCreds, setShowDemoCreds] = useState(false)
  const [resetNotice, setResetNotice] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    setValue,
    formState: { errors },
  } = useForm<LoginFormValues>({ resolver: zodResolver(loginSchema), mode: "onChange" })

  const signInMutation = useMutation({
    mutationFn: (values: LoginFormValues) => signInWithPassword(values.email, values.password),
  })

  const googleSignInMutation = useMutation({
    mutationFn: signInWithGoogle,
  })

  const resetMutation = useMutation({
    mutationFn: async (email: string) => {
      const { error } = await supabase.auth.resetPasswordForEmail(email)
      if (error) throw error
    },
  })

  // Already signed in (direct visit to /login, or right after a successful
  // sign-in — the session updates globally via onAuthStateChange).
  if (sessionLoading) return <FullPageLoader label={t("common.loading")} />
  if (session) {
    if (profileLoading) return <FullPageLoader label={t("common.loading")} />
    if (profile) return <Navigate to={roleHomePath(profile.role)} replace />
    // First-time Google sign-in: an auth user exists but no profiles row —
    // admin-created customers never get one until linked by mobile number.
    if ((profileError as { code?: string } | null)?.code === NO_PROFILE_ROW_CODE) {
      return <GoogleLinkAccountCard userId={session.user.id} />
    }
  }

  const onSubmit = handleSubmit((values) => signInMutation.mutate(values))

  const signInErrorMessage = (() => {
    if (!signInMutation.isError) return null
    const message = (signInMutation.error as Error).message
    return message.toLowerCase().includes("invalid") ? t("auth.invalidCredentials") : t("auth.genericSignInError")
  })()

  return (
    <div className="flex min-h-screen bg-bg">
      {/* Hero panel */}
      <div className="relative hidden w-1/2 flex-col justify-between overflow-hidden bg-ink px-12 py-10 text-white lg:flex">
        <div className="relative flex items-center gap-3">
          <img src="/logo-icon.svg" alt="GV Mart" className="size-12" />
          <div>
            <p className="text-lg font-bold leading-none">
              <span className="text-accent">GV</span>mart
            </p>
            <p className="text-xs uppercase tracking-wide text-white/60">{t("common.tagline")}</p>
          </div>
        </div>
        <div className="relative max-w-sm">
          <h1 className="text-3xl font-bold leading-tight">{t("auth.heroTitle")}</h1>
          <p className="mt-3 text-sm text-white/70">{t("auth.heroSubtitle")}</p>
        </div>
        <span className="relative inline-flex w-fit items-center gap-2 rounded-full bg-white/10 px-3 py-1.5 text-xs font-medium">
          <ShieldCheck className="size-3.5" />
          {t("auth.secureAccessBadge")}
        </span>
      </div>

      {/* Form panel */}
      <div className="flex w-full flex-col items-center justify-center px-6 py-10 lg:w-1/2">
        <div className="mb-6 flex w-full max-w-sm items-center justify-between lg:hidden">
          <img src="/logo-icon.svg" alt="GV Mart" className="size-11" />
          <LanguageToggle />
        </div>

        <div className="w-full max-w-sm">
          <div className="mb-6 hidden justify-end lg:flex">
            <LanguageToggle />
          </div>

          <p className="text-xs font-semibold uppercase tracking-wide text-accent">{t("auth.signInEyebrow")}</p>
          <h2 className="mt-1 text-2xl font-bold text-text">{t("auth.signInTitle")}</h2>
          <p className="mt-1 text-sm text-text-muted">{t("auth.signInSubtitle")}</p>

          <form className="mt-6 space-y-4" onSubmit={onSubmit} noValidate>
            <div className="space-y-1.5">
              <Label htmlFor="email">{t("auth.emailLabel")}</Label>
              <div className="relative">
                <Mail className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
                <Input
                  id="email"
                  type="email"
                  autoComplete="email"
                  placeholder={t("auth.emailPlaceholder")}
                  className="pl-10"
                  aria-invalid={!!errors.email}
                  {...register("email")}
                />
              </div>
            </div>

            <div className="space-y-1.5">
              <div className="flex items-center justify-between">
                <Label htmlFor="password">{t("auth.passwordLabel")}</Label>
                <button
                  type="button"
                  className="text-xs font-medium text-accent hover:underline"
                  onClick={() => {
                    const email = (document.getElementById("email") as HTMLInputElement | null)?.value
                    if (!email) return
                    resetMutation.mutate(email)
                    setResetNotice(t("auth.passwordResetSent"))
                  }}
                >
                  {t("auth.forgotPassword")}
                </button>
              </div>
              <div className="relative">
                <Lock className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
                <Input
                  id="password"
                  type={showPassword ? "text" : "password"}
                  autoComplete="current-password"
                  placeholder={t("auth.passwordPlaceholder")}
                  className="px-10"
                  aria-invalid={!!errors.password}
                  {...register("password")}
                />
                <button
                  type="button"
                  aria-label={showPassword ? "Hide password" : "Show password"}
                  className="absolute right-3.5 top-1/2 -translate-y-1/2 text-text-muted hover:text-text"
                  onClick={() => setShowPassword((v) => !v)}
                >
                  {showPassword ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                </button>
              </div>
            </div>

            {signInErrorMessage ? (
              <p role="alert" className="rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">
                {signInErrorMessage}
              </p>
            ) : null}
            {resetNotice ? (
              <p role="status" className="rounded-xl bg-info/10 px-3 py-2 text-sm text-info">
                {resetNotice}
              </p>
            ) : null}

            <Button type="submit" size="lg" className="w-full" disabled={signInMutation.isPending}>
              {signInMutation.isPending ? t("auth.signingIn") : t("auth.signInButton")}
            </Button>
          </form>

          <div className="my-5 flex items-center gap-3">
            <div className="h-px flex-1 bg-border" />
            <span className="text-xs font-medium uppercase text-text-muted">{t("auth.orDivider")}</span>
            <div className="h-px flex-1 bg-border" />
          </div>

          <Button
            type="button"
            variant="outline"
            size="lg"
            className="w-full gap-2.5"
            disabled={googleSignInMutation.isPending}
            onClick={() => googleSignInMutation.mutate()}
          >
            <GoogleLogo className="size-4.5 shrink-0" />
            {googleSignInMutation.isPending ? t("auth.signingIn") : t("auth.signInWithGoogle")}
          </Button>
          {googleSignInMutation.isError ? (
            <p role="alert" className="mt-2 rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">
              {t("auth.genericSignInError")}
            </p>
          ) : null}

          {import.meta.env.DEV ? (
            <div className="mt-4">
              <button
                type="button"
                className="w-full rounded-xl bg-surface-alt px-3.5 py-2.5 text-left text-sm font-medium text-text hover:bg-surface-alt/70"
                onClick={() => setShowDemoCreds((v) => !v)}
              >
                {t("auth.demoCredentialsToggle")}
              </button>
              {showDemoCreds ? (
                <div className="mt-2 space-y-1.5 rounded-xl border border-border p-3.5 text-sm">
                  {DEMO_LOGINS.map((d) => (
                    <button
                      key={d.role}
                      type="button"
                      className="flex w-full items-center justify-between rounded-lg px-2 py-1 text-left hover:bg-surface-alt"
                      onClick={() => {
                        setValue("email", d.email)
                        setValue("password", "GvMart@2026")
                      }}
                    >
                      <span className="font-medium text-text">{t(`roles.${d.role}`)}</span>
                      <span className="text-text-muted">{d.email}</span>
                    </button>
                  ))}
                  <p className="pt-1 text-xs text-text-muted">{t("auth.demoCredentialsPassword")}: GvMart@2026</p>
                </div>
              ) : null}
            </div>
          ) : null}

          <p className="mt-6 flex items-start gap-2 text-xs text-text-muted">
            <ShieldCheck className="mt-0.5 size-3.5 shrink-0" />
            {t("auth.trustNote")}
          </p>
        </div>
      </div>
    </div>
  )
}
