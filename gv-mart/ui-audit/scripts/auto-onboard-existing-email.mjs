// Manual verification: a Google sign-in whose email matches exactly one existing, unlinked
// customer lands on THAT customer's own data (name "__TEST_ existing", not a blank new profile).
// Run auto-onboard-seed.sql first.
// Usage: node ui-audit/scripts/auto-onboard-existing-email.mjs
import { chromium } from "playwright"
import { signInAs } from "./auto-onboard-lib.mjs"

;(async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  const errors = []
  page.on("pageerror", (err) => errors.push(err.message))

  await signInAs(page, "onboard-existing.test@gvmart.invalid")
  await page.waitForTimeout(1500)

  await page.goto("http://localhost:5173/customer/profile", { waitUntil: "networkidle" }).catch(() => {})
  const sawExistingName = (await page.getByText("__TEST_ existing").count()) > 0
  const onCustomerHome = new URL(page.url()).pathname.startsWith("/customer")

  console.log(
    JSON.stringify(
      {
        finalUrl: page.url(),
        onCustomerHome,
        sawExistingName,
        pageErrors: errors,
        expect: "onCustomerHome=true, sawExistingName=true (proves it linked to the pre-existing customer, not a fresh blank one)",
      },
      null,
      2
    )
  )

  await browser.close()
})()
