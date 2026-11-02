// Manual verification: a brand-new Google sign-in (zero email matches) lands on a clean new
// 'customer_app' customer, not stuck on any notice. Run auto-onboard-seed.sql first.
// Usage: node ui-audit/scripts/auto-onboard-new-user.mjs
import { chromium } from "playwright"
import { signInAs } from "./auto-onboard-lib.mjs"

;(async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  const errors = []
  page.on("pageerror", (err) => errors.push(err.message))

  await signInAs(page, "onboard-new.test@gvmart.invalid")
  await page.waitForTimeout(1500) // customer_auto_onboard() round-trip + profile invalidation

  const stuckOnLinkNotice = (await page.getByText(/account linking is not available|contact the shop/i).count()) > 0
  const onCustomerHome = new URL(page.url()).pathname.startsWith("/customer")

  console.log(
    JSON.stringify(
      {
        finalUrl: page.url(),
        stuckOnLinkNotice,
        onCustomerHome,
        pageErrors: errors,
        expect: "stuckOnLinkNotice=false, onCustomerHome=true",
      },
      null,
      2
    )
  )

  await browser.close()
})()
