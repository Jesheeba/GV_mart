import { Capacitor } from "@capacitor/core"
import type { PluginListenerHandle } from "@capacitor/core"
import { App } from "@capacitor/app"
import { Browser } from "@capacitor/browser"
import { supabase } from "@/lib/supabase"

export async function signInWithPassword(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({ email, password })
  if (error) throw error
  return data
}

/** Redirects to Google, then back to /login — the session lands via the URL fragment (supabase-js handles it automatically). */
export async function signInWithGoogle() {
  if (Capacitor.isNativePlatform()) return signInWithGoogleNative()

  const { error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: `${window.location.origin}/login` },
  })
  if (error) throw error
}

/** Custom scheme registered in AndroidManifest.xml / Info.plist to catch the OAuth redirect back into the app. */
const NATIVE_AUTH_CALLBACK_URL = "gvmart://auth-callback"

/**
 * Google blocks completing OAuth inside an embedded WebView, so on native we
 * open the system browser (Custom Tabs / SFSafariViewController) instead of
 * redirecting in-place, then catch the result via a custom URL scheme deep
 * link — the same session-in-URL-fragment shape the web flow relies on, just
 * delivered through `appUrlOpen` instead of `window.location`.
 */
async function signInWithGoogleNative(): Promise<void> {
  const { data, error } = await supabase.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: NATIVE_AUTH_CALLBACK_URL, skipBrowserRedirect: true },
  })
  if (error) throw error
  if (!data.url) throw new Error("Supabase did not return an OAuth URL")
  const oauthUrl = data.url

  return new Promise<void>((resolve, reject) => {
    let settled = false
    let appListener: PluginListenerHandle | null = null
    let browserListener: PluginListenerHandle | null = null

    App.addListener("appUrlOpen", ({ url }) => {
      if (settled) return
      settled = true
      void (async () => {
        try {
          const params = new URLSearchParams(new URL(url).hash.slice(1))
          const accessToken = params.get("access_token")
          const refreshToken = params.get("refresh_token")
          if (!accessToken || !refreshToken) {
            throw new Error(params.get("error_description") || "Google sign-in was cancelled")
          }
          const { error: sessionError } = await supabase.auth.setSession({
            access_token: accessToken,
            refresh_token: refreshToken,
          })
          if (sessionError) throw sessionError
          resolve()
        } catch (err) {
          reject(err instanceof Error ? err : new Error("Google sign-in failed"))
        } finally {
          await appListener?.remove()
          await browserListener?.remove()
          await Browser.close().catch(() => {})
        }
      })()
    }).then((handle) => {
      appListener = handle
    })

    Browser.addListener("browserFinished", () => {
      if (settled) return
      settled = true
      void appListener?.remove()
      void browserListener?.remove()
      reject(new Error("Google sign-in was cancelled"))
    }).then((handle) => {
      browserListener = handle
    })

    Browser.open({ url: oauthUrl })
  })
}

/**
 * First-time Google sign-in has a Supabase auth user but no `profiles` row —
 * admin-created customers (create_customer_with_details) never get one, see
 * 20260729130000_customer_google_link.sql.
 *
 * `link_customer_google_account` (the function this used to call) is
 * PERMANENTLY REVOKED (20261021100000) — it linked by a typed mobile number
 * alone with no proof of ownership (account-takeover hole, see
 * docs/security-link-customer-account.md). It must never be called or
 * re-granted. The replacement is the two OTP RPCs below
 * (20261120100000_customer_link_otp.sql): a phone number only starts a
 * verification code sent over WhatsApp through the existing outbox/
 * dispatcher; the account is linked only once that code is confirmed.
 */

/** Whether the OTP linking flow is turned on at all (server-side flag, default OFF — see
 * customer_link_otp_settings). Call this before showing the phone-number form; while it's
 * false the UI must show the "contact the shop" message instead of attempting any RPC call. */
export async function isCustomerLinkOtpEnabled(): Promise<boolean> {
  const { data, error } = await supabase.rpc("is_customer_link_otp_enabled")
  if (error) throw error
  return data === true
}

/** WP2 (docs/DECISIONS.md section 15): whether the non-blocking "link your phone" card on the
 * customer Home/Profile screens should render at all. Server-side eligibility (the caller's own
 * customer is the empty, auto-created "app" record, same test as the merge-on-verify migration
 * uses) -- the client never computes or guesses this itself, and the function returns false
 * (never throws) for anyone ineligible, including an unauthenticated caller or the flag being
 * off, so a query error here should also hide the card, not show it. */
export async function isCustomerLinkOtpCardEligible(): Promise<boolean> {
  const { data, error } = await supabase.rpc("customer_link_otp_card_eligible")
  if (error) throw error
  return data === true
}

export type RequestCustomerLinkCodeResult = { status: "ok"; message: string }

/** ALWAYS resolves to the same generic shape, whether or not `mobile` matches a customer, is
 * already linked, is a test customer, or was rate-limited — never branch UI copy on anything
 * other than this call throwing (which only happens for the caller's own invalid state: not
 * signed in, already has a profile, malformed number, or the feature flag is off). */
export async function requestCustomerLinkCode(mobile: string): Promise<RequestCustomerLinkCodeResult> {
  const { data, error } = await supabase.rpc("request_customer_link_code", { p_mobile: mobile })
  if (error) throw error
  return data as RequestCustomerLinkCodeResult
}

export type VerifyCustomerLinkCodeResult =
  | { status: "linked" }
  | { status: "invalid_or_expired"; attempts_left: number }

/** On `{ status: "linked" }` the caller's profiles row now exists — invalidate the profile query
 * so the app re-fetches it. On `{ status: "invalid_or_expired" }` show a single generic message
 * ("that code didn't work") plus the generic attempts-left count; never surface which specific
 * reason (wrong code / expired / already consumed / no challenge at all) caused it. */
export async function verifyCustomerLinkCode(code: string): Promise<VerifyCustomerLinkCodeResult> {
  const { data, error } = await supabase.rpc("verify_customer_link_code", { p_code: code })
  if (error) throw error
  return data as VerifyCustomerLinkCodeResult
}

/**
 * Auto-onboarding on first Google sign-in (20261130100001_customer_auto_onboard_rpc.sql) —
 * replaces linkCustomerGoogleAccount's dead-end for the common case. Takes no arguments; the
 * server reads the caller's own Google-verified email from auth.identities. Idempotent (safe to
 * call again on a page reload) and refuses with a `staff_account` message if the signed-in
 * Google account turns out to belong to a staff/technician/master profile.
 */
export async function customerAutoOnboard() {
  const { data, error } = await supabase.rpc("customer_auto_onboard")
  if (error) throw error
  return data
}

export async function signOut() {
  const { error } = await supabase.auth.signOut()
  if (error) throw error
}

export async function fetchProfile(userId: string) {
  const { data, error } = await supabase.from("profiles").select("*").eq("id", userId).single()
  if (error) throw error
  return data
}
