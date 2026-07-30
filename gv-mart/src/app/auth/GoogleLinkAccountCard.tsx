import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useTranslation } from "react-i18next"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Phone, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import { linkCustomerGoogleAccount, signOut } from "@/services/auth"

const MOBILE_REGEX = /^[6-9]\d{9}$/
const linkSchema = z.object({ mobile: z.string().regex(MOBILE_REGEX, "customers.errors.mobileInvalid") })
type LinkFormValues = z.infer<typeof linkSchema>

/**
 * Shown after a first-time Google sign-in when the auth user has no
 * `profiles` row — admin-created customers (create_customer_with_details)
 * never get one until linked. Asks for the mobile number staff already have
 * on file and calls link_customer_google_account (20260729130000) to attach
 * this auth user to that existing customer record.
 */
export function GoogleLinkAccountCard({ userId }: { userId: string }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LinkFormValues>({ resolver: zodResolver(linkSchema), mode: "onChange" })

  const linkMutation = useMutation({
    mutationFn: (values: LinkFormValues) => linkCustomerGoogleAccount(values.mobile),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["profile", userId] }),
  })

  const onSubmit = handleSubmit((values) => linkMutation.mutate(values))

  const linkErrorMessage = (() => {
    if (!linkMutation.isError) return null
    const message = (linkMutation.error as Error).message
    if (message.includes("not_found")) return t("auth.linkAccountNotFound")
    if (message.includes("already_linked")) return t("auth.linkAccountAlreadyLinked")
    return t("auth.linkAccountGenericError")
  })()

  return (
    <div className="flex min-h-screen items-center justify-center bg-bg px-6 py-10">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center justify-between">
          <img src="/logo-icon.svg" alt="GV Mart" className="size-11" />
          <LanguageToggle />
        </div>

        <p className="text-xs font-semibold uppercase tracking-wide text-accent">{t("auth.signInEyebrow")}</p>
        <h2 className="mt-1 text-2xl font-bold text-text">{t("auth.linkAccountTitle")}</h2>
        <p className="mt-1 text-sm text-text-muted">{t("auth.linkAccountSubtitle")}</p>

        <form className="mt-6 space-y-4" onSubmit={onSubmit} noValidate>
          <div className="space-y-1.5">
            <Label htmlFor="mobile">{t("auth.mobileLabel")}</Label>
            <div className="relative">
              <Phone className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
              <Input
                id="mobile"
                type="tel"
                inputMode="numeric"
                autoComplete="tel"
                placeholder={t("auth.mobilePlaceholder")}
                className="pl-10"
                aria-invalid={!!errors.mobile}
                {...register("mobile")}
              />
            </div>
            {errors.mobile ? <p className="text-xs text-danger">{t(errors.mobile.message!)}</p> : null}
          </div>

          {linkErrorMessage ? (
            <p role="alert" className="rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">
              {linkErrorMessage}
            </p>
          ) : null}

          <Button type="submit" size="lg" className="w-full" disabled={linkMutation.isPending}>
            {linkMutation.isPending ? t("auth.linkingAccount") : t("auth.linkAccountButton")}
          </Button>
        </form>

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
