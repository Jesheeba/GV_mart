// Confirms the sidebar's labels and collapse/expand tooltip render in Tamil
// when the language toggle is set to TA, at phone width. Not part of the
// app build — lives under ui-audit/ only.
import { chromium } from "playwright"
import { ensureDir, CREDS, PASSWORD } from "./audit-lib.mjs"
import path from "node:path"

const BASE_URL = "http://localhost:5174"
const OUT_DIR = "ui-audit/screenshots/sidebar-collapse"

;(async () => {
  ensureDir(OUT_DIR)
  const browser = await chromium.launch()
  const context = await browser.newContext({ viewport: { width: 375, height: 812 } })
  const page = await context.newPage()

  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.evaluate(() => localStorage.removeItem("gv_mart_admin_sidebar_collapsed"))
  await page.fill("#email", CREDS.master)
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})
  await page.waitForTimeout(500)

  // Flip to Tamil via the header toggle (same control every other page uses).
  await page.getByRole("radio", { name: "த" }).click()
  await page.waitForTimeout(400)

  const expandBtn = page.getByRole("button", { name: /சுருக்கு|விரிவாக்கு/i })
  const toggleAriaLabel = await expandBtn.getAttribute("aria-label")
  await expandBtn.click()
  await page.waitForTimeout(350)
  const firstLabel = await page.locator("aside nav a span.truncate").first().textContent()
  await page.screenshot({ path: path.join(OUT_DIR, "375-expanded-ta.png") })

  console.log(JSON.stringify({ toggleAriaLabel, firstLabel }, null, 2))

  await browser.close()
})()
