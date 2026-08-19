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
 * 20260729130000_customer_google_link.sql. This links the new auth user to
 * their existing customer record by mobile number and creates that profile.
 */
export async function linkCustomerGoogleAccount(mobile: string) {
  const { error } = await supabase.rpc("link_customer_google_account", { p_mobile: mobile })
  if (error) throw error
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
