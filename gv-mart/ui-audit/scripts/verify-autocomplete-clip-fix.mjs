// Verifies the Autocomplete dropdown is no longer clipped by an ancestor
// Card's overflow-hidden (New Complaint's Customer step, same scenario the
// user hit live). Not part of the app build — lives under ui-audit/ only.
import { chromium } from "playwright"
import { ensureDir, CREDS, PASSWORD } from "./audit-lib.mjs"
import path from "node:path"

const BASE_URL = "http://localhost:5175"
const OUT_DIR = "ui-audit/screenshots/autocomplete-clip-fix"

;(async () => {
  ensureDir(OUT_DIR)
  const browser = await chromium.launch()
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const page = await context.newPage()
  const errors = []
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text())
  })
  page.on("pageerror", (err) => errors.push("PAGEERROR: " + err.message))

  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", CREDS.master)
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})

  await page.goto(`${BASE_URL}/admin/service/new`, { waitUntil: "networkidle" })
  await page.waitForTimeout(500)
  // Discard any restored draft so we land cleanly on step 1 (Customer).
  const discardBtn = page.getByRole("button", { name: /discard draft/i })
  if ((await discardBtn.count()) > 0) {
    await discardBtn.click()
    await page.waitForTimeout(300)
  }

  await page.fill("#customer-search", "a")
  await page.waitForTimeout(900) // debounce + fetch

  const listbox = page.locator("[role='listbox']")
  const listboxVisible = await listbox.isVisible().catch(() => false)
  const optionCount = await page.locator("[role='option']").count()
  const listboxBox = await listbox.boundingBox().catch(() => null)
  // The bug: a Card ancestor's overflow-hidden clipping the dropdown height
  // to near-zero. If it's fixed, the box should be tall enough to show
  // more than one option row (~40px) whenever more than one match exists.
  const isPortalledToBody = await listbox.evaluate((el) => el.parentElement === document.body).catch(() => false)

  await page.screenshot({ path: path.join(OUT_DIR, "customer-search-dropdown.png") })

  console.log(
    JSON.stringify(
      {
        listboxVisible,
        optionCount,
        listboxBox,
        isPortalledToBody,
        consoleErrors: errors.slice(0, 5),
      },
      null,
      2
    )
  )

  await browser.close()
})()
