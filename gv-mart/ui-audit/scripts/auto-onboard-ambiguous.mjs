// Manual verification: a Google sign-in whose email matches TWO existing customers never picks
// one — it lands on a fresh, independent customer, and the master customer list shows that new
// row flagged "Needs review". Run auto-onboard-seed.sql first; this script signs in as the
// ambiguous-email user (customer app) AND, separately, checks the admin list as master — needs
// MASTER_EMAIL / MASTER_PASS env vars for that second part (same convention as the other
// ui-audit scripts that sign in as staff).
// Usage: node ui-audit/scripts/auto-onboard-ambiguous.mjs
import { chromium } from "playwright"
import { signInAs, BASE_URL } from "./auto-onboard-lib.mjs"

;(async () => {
  const browser = await chromium.launch()

  // Part 1: the customer-side experience.
  const customerPage = await browser.newPage()
  await signInAs(customerPage, "onboard-ambiguous.test@gvmart.invalid")
  await customerPage.waitForTimeout(1500)
  const customerLandedOk = new URL(customerPage.url()).pathname.startsWith("/customer")
  await customerPage.close()

  // Part 2: the master-side "Needs review" visibility, if staff creds are provided.
  let masterSawFlag = null
  if (process.env.MASTER_EMAIL && process.env.MASTER_PASS) {
    const masterPage = await browser.newPage()
    await masterPage.goto(`${BASE_URL}/login`)
    await masterPage.getByLabel(/email/i).fill(process.env.MASTER_EMAIL)
    await masterPage.getByRole("textbox", { name: /password/i }).fill(process.env.MASTER_PASS)
    await masterPage.getByRole("button", { name: "Sign in", exact: true }).click()
    await masterPage.waitForLoadState("networkidle")
    await masterPage.goto(`${BASE_URL}/admin/customers`, { waitUntil: "networkidle" })
    await masterPage.getByPlaceholder(/search/i).fill("ambig")
    await masterPage.waitForTimeout(800)
    masterSawFlag = (await masterPage.getByText(/needs review/i).count()) > 0
    await masterPage.close()
  }

  console.log(
    JSON.stringify(
      {
        customerLandedOk,
        masterSawFlag,
        note: masterSawFlag === null ? "part 2 skipped — set MASTER_EMAIL/MASTER_PASS to run it" : undefined,
        expect: "customerLandedOk=true (new, independent customer — never silently attached to either of the two ambiguous matches); masterSawFlag=true",
      },
      null,
      2
    )
  )

  await browser.close()
})()
