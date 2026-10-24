// Measures real network timing for the Customers list to find which
// request(s) are actually slow. Not part of the app build.
import { chromium } from "playwright"
import { CREDS, PASSWORD } from "./audit-lib.mjs"

const BASE_URL = "http://localhost:5176"

async function measurePage(page, url, label) {
  const starts = new Map()
  const durations = []
  const onRequest = (req) => {
    if (req.resourceType() !== "fetch" && req.resourceType() !== "xhr") return
    starts.set(req, Date.now())
  }
  const onFinished = (req) => {
    const start = starts.get(req)
    if (start == null) return
    durations.push({ url: req.url().replace(/^https?:\/\/[^/]+/, ""), ms: Date.now() - start })
  }
  page.on("request", onRequest)
  page.on("requestfinished", onFinished)
  const t0 = Date.now()
  await page.goto(`${BASE_URL}${url}`, { waitUntil: "networkidle", timeout: 30000 })
  const totalMs = Date.now() - t0
  page.off("request", onRequest)
  page.off("requestfinished", onFinished)
  durations.sort((a, b) => b.ms - a.ms)
  console.log(`\n=== ${label} (${url}) — total networkidle: ${totalMs}ms ===`)
  for (const r of durations.slice(0, 12)) {
    console.log(`  ${String(r.ms).padStart(5)}ms  ${r.url.slice(0, 150)}`)
  }
}

;(async () => {
  const browser = await chromium.launch()
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } })
  const page = await context.newPage()

  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", CREDS.master)
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})
  await page.waitForTimeout(1000) // let AdminShell's own background pollers settle before measuring

  await measurePage(page, "/admin/customers", "Customers list")
  await page.waitForTimeout(500)
  await measurePage(page, "/admin/customers", "Customers list (2nd visit)")

  await browser.close()
})()
