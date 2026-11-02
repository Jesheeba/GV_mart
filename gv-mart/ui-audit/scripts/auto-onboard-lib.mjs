// Shared helper for the 3 auto-onboard Playwright scripts. Not part of the app build — lives
// under ui-audit/ only, same convention as audit-lib.mjs.
//
// Driving a real Google OAuth consent screen from a script isn't practical (and isn't what
// these scripts are trying to prove) — customer_auto_onboard() only cares that the session's
// auth.uid() has a confirmed Google identity, not how that session was established. These
// scripts establish a real Supabase session for one of auto-onboard-seed.sql's already-seeded
// test users via the Admin API's magic-link flow (the standard way to test an
// auth-gated flow end to end without driving a third-party IdP's UI), then let the app's own
// code run customer_auto_onboard() exactly as it would for a real Google sign-in.
import { createClient } from "@supabase/supabase-js"

export const BASE_URL = "http://localhost:5173"

const SUPABASE_URL = process.env.VITE_SUPABASE_URL
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY
if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
  throw new Error(
    "VITE_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must both be set (never printed, never committed) " +
      "to run any auto-onboard-*.mjs script — they call the Supabase Admin API to sign in as a " +
      "pre-seeded test user (see auto-onboard-seed.sql). Run that seed script first."
  )
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { autoRefreshToken: false, persistSession: false } })

/** Opens `page` already signed in as `email` (must already exist — see auto-onboard-seed.sql), landing on /login so the app's own post-sign-in routing (including customer_auto_onboard()) runs exactly as it would for a real Google sign-in. */
export async function signInAs(page, email) {
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email })
  if (error) throw new Error(`generateLink failed for ${email}: ${error.message}`)
  const verifyUrl = data.properties?.action_link
  if (!verifyUrl) throw new Error(`no action_link returned for ${email}`)
  await page.goto(verifyUrl, { waitUntil: "networkidle" })
  // The magic-link verify redirect lands wherever Supabase's own redirect_to default points —
  // normalize to /login so every script's assertions start from the same place LoginPage's own
  // Google-sign-in redirect does.
  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
}
