// Checks the actual deployed Vercel preview for the New Complaint booking-UI
// parity change and the sidebar rework. Not part of the app build — lives
// under ui-audit/ only.
import { chromium } from "playwright"
import { ensureDir, CREDS, PASSWORD } from "./audit-lib.mjs"
import path from "node:path"

const BASE_URL = "https://gv-mart-f8pxvgbc1-jesheeba-fathimas-projects.vercel.app"
const OUT_DIR = "ui-audit/screenshots/vercel-live"

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
  await page.screenshot({ path: path.join(OUT_DIR, "00-login.png") })

  const loginUrl = page.url()
  const hasLoginForm = (await page.locator("#email").count()) > 0

  let deployedCommit = null
  if (hasLoginForm) {
    await page.fill("#email", CREDS.master)
    await page.fill("#password", PASSWORD)
    await page.click('button[type="submit"]')
    await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 }).catch(() => {})
    await page.waitForLoadState("networkidle").catch(() => {})
  }

  await page.goto(`${BASE_URL}/admin/service/new`, { waitUntil: "networkidle" })
  await page.waitForTimeout(600)
  await page.screenshot({ path: path.join(OUT_DIR, "01-new-complaint-step0.png") })

  // Sidebar check first (whatever step we land on has the shell around it).
  const asideWidth = await page.locator("aside").first().evaluate((el) => el.getBoundingClientRect().width).catch(() => null)
  const toggleExists = (await page.getByRole("button", { name: /collapse sidebar|expand sidebar/i }).count()) > 0
  const labelVisible = await page.locator("aside nav a span.truncate").first().isVisible().catch(() => false)

  console.log(
    JSON.stringify(
      {
        loginUrl,
        hasLoginForm,
        currentUrl: page.url(),
        asideWidth,
        toggleExists,
        labelVisibleByDefault: labelVisible,
        consoleErrors: errors.slice(0, 10),
      },
      null,
      2
    )
  )

  await browser.close()
})()
