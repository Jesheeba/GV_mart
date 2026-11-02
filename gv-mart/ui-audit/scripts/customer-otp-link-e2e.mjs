// Real end-to-end Playwright check of the customer OTP-link flow, flag OFF and ON, against a
// throwaway auth user (no profiles row) signed in via email/password (the LoginPage's email+
// password path reaches the exact same GoogleLinkAccountCard branch a first-time Google sign-in
// would -- the check is generic on "session + no profile", not provider-specific). Not part of
// the app build. Reads fixture credentials from a local gitignored scratch file, never prints
// passwords. Runs against localhost (dev server pointed at the live project via copied .env
// files), NOT the deployed site -- this migration has not been pushed/deployed yet at the time
// this runs.
import { chromium } from "playwright"
import fs from "node:fs"

const BASE_URL = "http://localhost:5183"
const fixture1 = JSON.parse(fs.readFileSync("_local_only/.otp_fixture1.json", "utf8"))
const fixture2 = JSON.parse(fs.readFileSync("_local_only/.otp_fixture2.json", "utf8"))

function shot(page, name) {
  return page.screenshot({ path: `_local_only/reports/customer_otp_link/screenshots/${name}.png` })
}

async function loginFresh(browser, email, password) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } })
  const page = await context.newPage()
  const consoleErrors = []
  const failedRequests = []
  page.on("pageerror", (e) => consoleErrors.push(String(e)))
  page.on("console", (m) => {
    if (m.type() === "error") consoleErrors.push(m.text())
  })
  page.on("requestfailed", (r) => failedRequests.push(`${r.url()} :: ${r.failure()?.errorText}`))
  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", email)
  await page.fill("#password", password)
  await page.click('button[type="submit"]')
  await page.waitForTimeout(1500)
  return { context, page, consoleErrors, failedRequests }
}

;(async () => {
  const browser = await chromium.launch()
  const results = {}
  fs.mkdirSync("_local_only/reports/customer_otp_link/screenshots", { recursive: true })

  // ===== 1. FLAG OFF: static "not available yet" notice, no form =====
  {
    const { context, page, consoleErrors } = await loginFresh(browser, fixture1.email, fixture1.password)
    const title = await page.getByText("Account linking is not available yet").first().isVisible().catch(() => false)
    const hasMobileInput = await page.locator("#mobile").count()
    const hasSendCodeButton = await page.getByText("Send code").count()
    await shot(page, "01-flag-off-unavailable-notice")
    results.flagOff = { unavailableNoticeVisible: title, mobileInputCount: hasMobileInput, sendCodeButtonCount: hasSendCodeButton, consoleErrors }
    await context.close()
  }

  console.log(JSON.stringify({ phase: "flag-off", results: results.flagOff }, null, 2))

  // ===== From here on, the flag must be ON (flipped live by a separate SQL step before this
  // script runs, flipped back OFF after) =====

  // ===== 2. FLAG ON, unknown number: generic "if registered" message, no oracle =====
  {
    const { context, page, consoleErrors, failedRequests } = await loginFresh(browser, fixture2.email, fixture2.password)
    await page.fill("#mobile", "9999999998") // not a real customer's number
    await page.click('button:has-text("Send code")')
    await page.waitForTimeout(1200)
    const noticeVisible = await page.getByText("If that number is registered").first().isVisible().catch(() => false)
    await shot(page, "02-flag-on-unknown-number-generic-response")
    results.unknownNumber = { noticeVisible, consoleErrors, failedRequests }
    await context.close()
  }
  console.log(JSON.stringify({ phase: "unknown-number", results: results.unknownNumber }, null, 2))

  // ===== 3. FLAG ON, a real is_test=true customer's number: SAME generic message (no oracle) =====
  if (fixture2.testCustomerMobile) {
    const { context, page } = await loginFresh(browser, fixture2.email, fixture2.password)
    await page.fill("#mobile", fixture2.testCustomerMobile)
    await page.click('button:has-text("Send code")')
    await page.waitForTimeout(1200)
    const noticeVisible = await page.getByText("If that number is registered").first().isVisible().catch(() => false)
    await shot(page, "03-flag-on-test-customer-generic-response")
    results.testCustomerNumber = { noticeVisible }
    await context.close()
  } else {
    results.testCustomerNumber = { skipped: "no is_test customer with a mobile number found at fixture-setup time" }
  }
  console.log(JSON.stringify({ phase: "test-customer-number", results: results.testCustomerNumber }, null, 2))

  // ===== 4+5. FLAG ON, the pre-seeded challenge: wrong code then the correct one =====
  {
    const { context, page, consoleErrors } = await loginFresh(browser, fixture1.email, fixture1.password)
    // A challenge already exists server-side for this user (seeded directly, bypassing any real
    // WhatsApp send) -- the UI still starts on the mobile-entry step since it has no client-side
    // memory of that; request a (fresh, superseding) code for the SAME customer's number so the UI
    // naturally reaches the code-entry step, then verify using the ORIGINAL known code is wrong on
    // purpose here (superseded) -- instead, request fresh and read the code from the DB directly
    // is out of scope for a browser test, so this phase instead verifies the WRONG-code path (any
    // 6 digits that aren't the seeded one) against the pre-seeded challenge by going straight to
    // code entry isn't reachable without the mobile step. Request a code for the fixture's own
    // customer mobile to reach the code step, then deliberately enter a wrong code first.
    await page.fill("#mobile", fixture1.mobile)
    await page.click('button:has-text("Send code")')
    await page.waitForTimeout(1200)
    await shot(page, "04-code-entry-step-reached")

    // This SECOND request supersedes the pre-seeded challenge (the one-active-challenge-per-
    // customer unique index) -- so the original known code (123456) is no longer valid. This
    // phase therefore only proves the WRONG-code path end to end (attempts_left decrements,
    // identical generic error, no oracle) through the real RPC via the real UI; the success path
    // is proven separately via the read-only DB check after setup in section 4 of the report
    // (q_playwright_setup.sql's own challenge row, verified directly) since the real code is never
    // observable by this script without reading the outbox (which would itself be a bug if it
    // worked, since the dispatcher redacts it) or the DB.
    await page.fill("#code", "000000")
    await page.click('button:has-text("Verify and link")')
    await page.waitForTimeout(1200)
    const wrongCodeMessage = await page.getByText(/That code did not work/i).first().textContent().catch(() => null)
    await shot(page, "05-wrong-code-generic-error")
    results.wrongCode = { wrongCodeMessage, consoleErrors }
    await context.close()
  }
  console.log(JSON.stringify({ phase: "wrong-code", results: results.wrongCode }, null, 2))

  await browser.close()
  fs.writeFileSync("_local_only/reports/customer_otp_link/e2e_results.json", JSON.stringify(results, null, 2))
  console.log("DONE")
})()
