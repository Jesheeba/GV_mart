import { useEffect, useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useTranslation } from "react-i18next"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Phone, ShieldCheck } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { LanguageToggle } from "@/components/shared/LanguageToggle"
import {
  isCustomerLinkOtpEnabled,
  requestCustomerLinkCode,
  signOut,
  verifyCustomerLinkCode,
  type VerifyCustomerLinkCodeResult,
} from "@/services/auth"

const MOBILE_REGEX = /^[6-9]\d{9}$/
const CODE_REGEX = /^\d{6}$/
const RESEND_COOLDOWN_SECONDS = 30

const mobileSchema = z.object({ mobile: z.string().regex(MOBILE_REGEX, "customers.errors.mobileInvalid") })
type MobileFormValues = z.infer<typeof mobileSchema>

const codeSchema = z.object({ code: z.string().regex(CODE_REGEX, "auth.linkAccountCodeInvalidFormat") })
type CodeFormValues = z.infer<typeof codeSchema>

type Step = "mobile" | "code"

/** Pure, independently testable (see GoogleLinkAccountCard.test.ts) — how many seconds remain
 * before "Resend code" is clickable again, never negative. */
export function computeCooldownSeconds(lastRequestedAt: number, now: number): number {
  const remaining = RESEND_COOLDOWN_SECONDS - Math.floor((now - lastRequestedAt) / 1000)
  return Math.max(remaining, 0)
}

/** Pure selection of which i18n key (and, for the attempts-remaining case, which interpolation
 * value) to show after a verify attempt — kept separate from the component so the "never show a
 * different shape for wrong vs expired vs locked vs no-challenge-at-all" rule (every non-success
 * case collapses to the same two outcomes here) is independently testable without rendering
 * anything. Returns null when there is nothing to show yet. */
export function selectVerifyErrorMessageKey(
  verifyResult: VerifyCustomerLinkCodeResult | null,
  isError: boolean
): { key: string; attemptsLeft?: number } | null {
  if (isError) return { key: "auth.linkAccountVerifyFailed" }
  if (!verifyResult || verifyResult.status === "linked") return null
  return verifyResult.attempts_left > 0
    ? { key: "auth.linkAccountInvalidOrExpired", attemptsLeft: verifyResult.attempts_left }
    : { key: "auth.linkAccountLockedOrExpired" }
}

/**
 * Shown after a first-time Google sign-in when the auth user has no
 * `profiles` row — admin-created customers (create_customer_with_details)
 * never get one until linked.
 *
 * Replaces the old trust-the-typed-number flow (`link_customer_google_account`,
 * permanently revoked — see docs/security-link-customer-account.md) with an
 * OTP challenge: a phone number only starts a verification code sent over
 * WhatsApp through the existing outbox/dispatcher (20261120100000); the
 * account is linked only once that code is confirmed
 * (request_customer_link_code / verify_customer_link_code).
 *
 * Shipped behind a server-side flag (customer_link_otp_settings, default
 * OFF) — see isCustomerLinkOtpEnabled(). While off, this screen shows a
 * "not available yet" message instead of any form, so nothing is sent to a
 * real customer until the owner explicitly turns the flag on.
 */
export function GoogleLinkAccountCard({ userId }: { userId: string }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [step, setStep] = useState<Step>("mobile")
  const [lastRequestedAt, setLastRequestedAt] = useState<number | null>(null)
  const [cooldownLeft, setCooldownLeft] = useState(0)
  const [verifyResult, setVerifyResult] = useState<VerifyCustomerLinkCodeResult | null>(null)

  const flagQuery = useQuery({
    queryKey: ["customer-link-otp-enabled"],
    queryFn: isCustomerLinkOtpEnabled,
  })

  const mobileForm = useForm<MobileFormValues>({ resolver: zodResolver(mobileSchema), mode: "onChange" })
  const codeForm = useForm<CodeFormValues>({ resolver: zodResolver(codeSchema), mode: "onChange" })

  const requestMutation = useMutation({
    mutationFn: (values: MobileFormValues) => requestCustomerLinkCode(values.mobile),
    onSuccess: () => {
      setLastRequestedAt(Date.now())
      setVerifyResult(null)
      setStep("code")
    },
  })

  const verifyMutation = useMutation({
    mutationFn: (values: CodeFormValues) => verifyCustomerLinkCode(values.code),
    onSuccess: (result) => {
      setVerifyResult(result)
      if (result.status === "linked") {
        void queryClient.invalidateQueries({ queryKey: ["profile", userId] })
      }
    },
  })

  useEffect(() => {
    if (lastRequestedAt === null) return
    const tick = () => setCooldownLeft(computeCooldownSeconds(lastRequestedAt, Date.now()))
    tick()
    const interval = setInterval(tick, 1000)
    return () => clearInterval(interval)
  }, [lastRequestedAt])

  const onSubmitMobile = mobileForm.handleSubmit((values) => requestMutation.mutate(values))
  const onSubmitCode = codeForm.handleSubmit((values) => verifyMutation.mutate(values))

  const onResend = () => {
    const mobile = mobileForm.getValues("mobile")
    if (cooldownLeft > 0 || !mobile) return
    requestMutation.mutate({ mobile })
  }

  const changeNumber = () => {
    setStep("mobile")
    setVerifyResult(null)
    codeForm.reset()
  }

  // Flag still loading: render nothing distinguishable from either final state (avoids a flash
  // of the wrong screen) — a brief blank frame is preferable to a flicker that itself leaks
  // which state the flag is in before the query settles.
  if (flagQuery.isLoading) {
    return <div className="flex min-h-screen items-center justify-center bg-bg" />
  }

  if (flagQuery.isError || flagQuery.data !== true) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-bg px-6 py-10">
        <div className="w-full max-w-sm text-center">
          <div className="mb-6 flex items-center justify-between">
            <img src="/logo-icon.svg" alt="GV Mart" className="size-11" />
            <LanguageToggle />
          </div>
          <h2 className="text-2xl font-bold text-text">{t("auth.linkAccountUnavailableTitle")}</h2>
          <p className="mt-3 text-sm text-text-muted">{t("auth.linkAccountUnavailableBody")}</p>
          <button
            type="button"
            className="mt-6 w-full text-center text-xs font-medium text-text-muted hover:text-text hover:underline"
            onClick={() => signOut()}
          >
            {t("auth.useDifferentAccount")}
          </button>
        </div>
      </div>
    )
  }

  const requestErrorMessage = requestMutation.isError ? t("auth.linkAccountRequestFailed") : null
  const verifyErrorSelection = selectVerifyErrorMessageKey(verifyResult, verifyMutation.isError)
  const verifyErrorMessage = verifyErrorSelection
    ? t(verifyErrorSelection.key, { attemptsLeft: verifyErrorSelection.attemptsLeft })
    : null

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

        {step === "mobile" ? (
          <form className="mt-6 space-y-4" onSubmit={onSubmitMobile} noValidate>
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
                  aria-invalid={!!mobileForm.formState.errors.mobile}
                  {...mobileForm.register("mobile")}
                />
              </div>
              {mobileForm.formState.errors.mobile ? (
                <p className="text-xs text-danger">{t(mobileForm.formState.errors.mobile.message!)}</p>
              ) : null}
            </div>

            {requestErrorMessage ? (
              <p role="alert" className="rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">
                {requestErrorMessage}
              </p>
            ) : null}

            <Button type="submit" size="lg" className="w-full" disabled={requestMutation.isPending}>
              {requestMutation.isPending ? t("auth.linkAccountSendingCode") : t("auth.linkAccountSendCode")}
            </Button>
          </form>
        ) : (
          <form className="mt-6 space-y-4" onSubmit={onSubmitCode} noValidate>
            <p role="status" className="rounded-xl bg-accent/10 px-3 py-2 text-sm text-text">
              {t("auth.linkAccountCodeSentNotice")}
            </p>

            <div className="space-y-1.5">
              <Label htmlFor="code">{t("auth.linkAccountCodeLabel")}</Label>
              <Input
                id="code"
                type="text"
                inputMode="numeric"
                autoComplete="one-time-code"
                maxLength={6}
                placeholder={t("auth.linkAccountCodePlaceholder")}
                aria-invalid={!!codeForm.formState.errors.code}
                {...codeForm.register("code")}
              />
              {codeForm.formState.errors.code ? (
                <p className="text-xs text-danger">{t(codeForm.formState.errors.code.message!)}</p>
              ) : null}
            </div>

            {verifyErrorMessage ? (
              <p role="alert" className="rounded-xl bg-danger/10 px-3 py-2 text-sm text-danger">
                {verifyErrorMessage}
              </p>
            ) : null}

            <Button type="submit" size="lg" className="w-full" disabled={verifyMutation.isPending}>
              {verifyMutation.isPending ? t("auth.linkAccountVerifyingCode") : t("auth.linkAccountVerifyButton")}
            </Button>

            <div className="flex items-center justify-between text-xs">
              <button type="button" className="font-medium text-text-muted hover:text-text hover:underline" onClick={changeNumber}>
                {t("auth.linkAccountChangeNumber")}
              </button>
              <button
                type="button"
                className="font-medium text-text-muted hover:text-text hover:underline disabled:opacity-50"
                disabled={cooldownLeft > 0 || requestMutation.isPending}
                onClick={onResend}
              >
                {cooldownLeft > 0 ? t("auth.linkAccountResendCooldown", { seconds: cooldownLeft }) : t("auth.linkAccountResendCode")}
              </button>
            </div>
          </form>
        )}

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
