// Playwright smoke check for the customer-OTP-link build (phase 1). Not part of the app build —
// lives under ui-audit/ only, same as the other one-off Playwright scripts here.
//
// What this DOES verify: the /login page (which the GoogleLinkAccountCard screen hangs off of)
// still renders cleanly after this branch's changes — no console errors, the Google sign-in
// button is present, the page loads — using the project's existing chromium.launch() pattern
// (no `playwright install`, per the task's instruction).
//
// What this DOES NOT verify, and why: reaching the "One more step" screen itself requires a real
// Supabase auth session for a signed-in Google user with no profiles row. There is no scriptable
// way to fabricate that session in this environment (Google OAuth cannot be driven headlessly
// without real test credentials, and this app has no demo-login shortcut for that specific
// "signed in, no profile yet" state the way it does for established staff/technician/customer
// logins). The two states that screen needs to prove — flag OFF ("contact the shop" message) and
// flag ON (phone -> code entry, generic errors, cooldown) — are instead covered directly against
// the pure logic Vitest exercises in src/app/auth/GoogleLinkAccountCard.test.ts
// (computeCooldownSeconds, selectVerifyErrorMessageKey), and the flag-off/flag-on BRANCH in the
// component itself was exercised by hand-tracing the rendered JSX for both `flagQuery.data`
// values (false/undefined and true) during development. Full end-to-end UI verification of this
// screen against a live Google-authenticated session is deferred to phase 2, once the migration
// is actually applied and a real OAuth round-trip is possible.
import { chromium } from "playwright"

const BASE_URL = "http://localhost:5173"

async function main() {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  const consoleErrors = []
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text())
  })
  page.on("pageerror", (err) => consoleErrors.push(String(err)))

  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  const title = await page.title()
  const googleButton = await page.getByText(/sign in with google/i).first().isVisible().catch(() => false)

  await page.screenshot({ path: "ui-audit/screenshots/customer-otp-link-login-page.png" })
  await browser.close()

  console.log("title:", title)
  console.log("google sign-in button visible:", googleButton)
  console.log("console errors:", consoleErrors.length === 0 ? "none" : consoleErrors)

  if (!googleButton) {
    console.error("FAIL: Google sign-in button not found on /login")
    process.exitCode = 1
    return
  }
  if (consoleErrors.length > 0) {
    console.error("FAIL: console errors present")
    process.exitCode = 1
    return
  }
  console.log("ok: /login renders cleanly with the Google sign-in entry point, no console errors")
}

main()
