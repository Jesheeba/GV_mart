import { useEffect, useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useTranslation } from "react-i18next"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Phone, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card } from "@/components/ui/card"
import {
  isCustomerLinkOtpCardEligible,
  requestCustomerLinkCode,
  verifyCustomerLinkCode,
  type VerifyCustomerLinkCodeResult,
} from "@/services/auth"

const MOBILE_REGEX = /^[6-9]\d{9}$/
const CODE_REGEX = /^\d{6}$/
const RESEND_COOLDOWN_SECONDS = 30
const DISMISSED_STORAGE_KEY = "gvmart.linkPhoneCard.dismissedAt"

const mobileSchema = z.object({ mobile: z.string().regex(MOBILE_REGEX, "customers.errors.mobileInvalid") })
type MobileFormValues = z.infer<typeof mobileSchema>

const codeSchema = z.object({ code: z.string().regex(CODE_REGEX, "auth.linkAccountCodeInvalidFormat") })
type CodeFormValues = z.infer<typeof codeSchema>

type Step = "mobile" | "code" | "linked"

/** Pure, independently testable -- same helper GoogleLinkAccountCard already uses, duplicated
 * rather than imported across two otherwise-unrelated components (login-time vs in-app). */
export function computeCooldownSeconds(lastRequestedAt: number, now: number): number {
  const remaining = RESEND_COOLDOWN_SECONDS - Math.floor((now - lastRequestedAt) / 1000)
  return Math.max(remaining, 0)
}

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

/** Pure, independently testable (see LinkPhoneCard.test.ts) -- the ONE decision that hides this
 * card entirely: dismissed by the viewer, the eligibility query still loading, that query having
 * errored, or the server having said false (flag off for this caller, or the caller's customer is
 * not the empty auto-created shape). Every one of these hides the card -- there is no case where
 * an inconclusive or negative answer still shows the form. Kept as its own function, separate
 * from the component, specifically so "the card must not render at all while ineligible" is
 * provable directly, not just by reading the component's own early-return and trusting it. */
export function shouldHideLinkPhoneCard(input: {
  dismissed: boolean
  isLoading: boolean
  isError: boolean
  eligible: boolean | undefined
}): boolean {
  return input.dismissed || input.isLoading || input.isError || input.eligible !== true
}

/** Best-effort, per-device "not now" dismissal -- a per-viewer convenience (does not need to
 * persist reliably or sync anywhere), so a try/catch around localStorage is enough; if it throws
 * or is unavailable the card simply offers "Not now" again next time, which is harmless. */
function readDismissed(): boolean {
  try {
    return localStorage.getItem(DISMISSED_STORAGE_KEY) !== null
  } catch {
    return false
  }
}
function writeDismissed() {
  try {
    localStorage.setItem(DISMISSED_STORAGE_KEY, String(Date.now()))
  } catch {
    // ignored -- per-viewer convenience only
  }
}

/**
 * WP2 (docs/DECISIONS.md section 15), owner-approved product decision: a non-blocking card on
 * the customer Home and Profile screens -- NOT a login-time gate, NOT part of LoginPage or
 * CustomerAutoOnboardGate, which stay untouched. Renders NOTHING (not even a loading placeholder
 * -- unlike the login-time GoogleLinkAccountCard, a brief absence here causes no flash of the
 * wrong full-page state, since this is one small card among many on an already-rendered page)
 * unless `customer_link_otp_card_eligible()` returns true: `customer_link_otp_settings.enabled`
 * is on AND the caller's own customer is the empty, auto-created ("app") record -- the exact same
 * eligibility test the merge-on-verify migration uses, read server-side only, never guessed or
 * computed from data this component has (it has none beyond the query's own boolean result).
 *
 * Flow: enter mobile -> code arrives on WhatsApp -> enter code -> on success, the one shared
 * response shape `{status: "linked"}` either means "merged onto the matched customer" or "claimed
 * this exact mobile for the caller's own record" -- this component does not know or need to know
 * which; either way it invalidates every query so the app re-fetches fresh data ("refresh the
 * app", the owner's own words) and shows a brief success state before disappearing (the
 * eligibility query itself is invalidated too, so a re-render correctly stops offering the card
 * again). On every non-"linked" outcome the response shape/wording is identical to
 * GoogleLinkAccountCard's own collapsed generic shape -- no new oracle introduced here either.
 */
export function LinkPhoneCard() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [step, setStep] = useState<Step>("mobile")
  const [lastRequestedAt, setLastRequestedAt] = useState<number | null>(null)
  const [cooldownLeft, setCooldownLeft] = useState(0)
  const [verifyResult, setVerifyResult] = useState<VerifyCustomerLinkCodeResult | null>(null)
  const [dismissed, setDismissed] = useState(readDismissed)

  const eligibleQuery = useQuery({
    queryKey: ["customer-link-otp-card-eligible"],
    queryFn: isCustomerLinkOtpCardEligible,
    // A query error must hide the card, exactly like "not eligible" -- never show a form the
    // server-side check could not actually confirm is safe to offer.
    retry: false,
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
        setStep("linked")
        // "refresh the app" -- the owner's own words: invalidate everything rather than guessing
        // which queries a merge vs a claim-own-number touched (customer id, profile, addresses,
        // AMC, warranties, and the eligibility check itself so the card correctly stops offering
        // itself again).
        void queryClient.invalidateQueries()
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

  if (shouldHideLinkPhoneCard({ dismissed, isLoading: eligibleQuery.isLoading, isError: eligibleQuery.isError, eligible: eligibleQuery.data })) {
    return null
  }

  const onSubmitMobile = mobileForm.handleSubmit((values) => requestMutation.mutate(values))
  const onSubmitCode = codeForm.handleSubmit((values) => verifyMutation.mutate(values))

  const onResend = () => {
    const mobile = mobileForm.getValues("mobile")
    if (cooldownLeft > 0 || !mobile) return
    requestMutation.mutate({ mobile })
  }

  const onDismiss = () => {
    writeDismissed()
    setDismissed(true)
  }

  const requestErrorMessage = requestMutation.isError ? t("auth.linkAccountRequestFailed") : null
  const verifyErrorSelection = selectVerifyErrorMessageKey(verifyResult, verifyMutation.isError)
  const verifyErrorMessage = verifyErrorSelection
    ? t(verifyErrorSelection.key, { attemptsLeft: verifyErrorSelection.attemptsLeft })
    : null

  if (step === "linked") {
    return (
      <Card className="gap-2 border-success/30 bg-success/5 px-4 py-3">
        <p className="text-sm font-medium text-text">{t("customerApp.linkPhoneCard.success")}</p>
      </Card>
    )
  }

  return (
    <Card className="gap-3 px-4 py-4">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-sm font-semibold text-text">{t("customerApp.linkPhoneCard.title")}</p>
          <p className="mt-0.5 text-xs text-text-muted">{t("customerApp.linkPhoneCard.subtitle")}</p>
        </div>
        <button
          type="button"
          onClick={onDismiss}
          aria-label={t("customerApp.linkPhoneCard.dismiss")}
          className="shrink-0 rounded-full p-1 text-text-muted hover:bg-surface-alt/60"
        >
          <X className="size-4" />
        </button>
      </div>

      {step === "mobile" ? (
        <form className="space-y-3" onSubmit={onSubmitMobile} noValidate>
          <div className="space-y-1.5">
            <Label htmlFor="link-phone-mobile">{t("auth.mobileLabel")}</Label>
            <div className="relative">
              <Phone className="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-text-muted" />
              <Input
                id="link-phone-mobile"
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

          <Button type="submit" size="sm" className="w-full" disabled={requestMutation.isPending}>
            {requestMutation.isPending ? t("auth.linkAccountSendingCode") : t("auth.linkAccountSendCode")}
          </Button>
        </form>
      ) : (
        <form className="space-y-3" onSubmit={onSubmitCode} noValidate>
          <p role="status" className="rounded-xl bg-accent/10 px-3 py-2 text-sm text-text">
            {t("auth.linkAccountCodeSentNotice")}
          </p>

          <div className="space-y-1.5">
            <Label htmlFor="link-phone-code">{t("auth.linkAccountCodeLabel")}</Label>
            <Input
              id="link-phone-code"
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

          <Button type="submit" size="sm" className="w-full" disabled={verifyMutation.isPending}>
            {verifyMutation.isPending ? t("auth.linkAccountVerifyingCode") : t("auth.linkAccountVerifyButton")}
          </Button>

          <div className="flex items-center justify-between text-xs">
            <button
              type="button"
              className="font-medium text-text-muted hover:text-text hover:underline"
              onClick={() => {
                setStep("mobile")
                setVerifyResult(null)
                codeForm.reset()
              }}
            >
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
    </Card>
  )
}
