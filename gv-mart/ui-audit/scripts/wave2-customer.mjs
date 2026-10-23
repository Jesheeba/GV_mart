// Phase 2, Wave 2 — Customer area capture (screenshots + console errors + axe)
import { chromium } from "playwright"
import { WIDTHS, newContext, login, visitAndCapture, writeLog } from "./audit-lib.mjs"
import path from "node:path"

const OUT_ROOT = path.resolve("ui-audit/screenshots/before/customer")
const LOG_PATH = path.resolve("ui-audit/screenshots/before/customer/_log.json")

const STATIC_PAGES = [
  { url: "/customer", name: "01-home" },
  { url: "/customer/products", name: "02-products" },
  { url: "/customer/bookings", name: "03-bookings" },
  { url: "/customer/profile", name: "04-profile" },
  { url: "/customer/amc", name: "05-amc" },
  { url: "/customer/book-service", name: "06-book-service" },
  { url: "/customer/product-enquiry", name: "07-product-enquiry" },
  { url: "/customer/product-enquiry/callback", name: "08-request-callback" },
  { url: "/customer/product-enquiry/compare", name: "09-compare" },
  { url: "/customer/spare-enquiry", name: "10-spare-enquiry" },
  { url: "/customer/notifications", name: "11-notifications" },
]

async function run(widthKey, { deepModals }) {
  const vp = WIDTHS[widthKey]
  const outDir = path.join(OUT_ROOT, vp.name)
  const browser = await chromium.launch()
  const { context, page, consoleErrors } = await newContext(browser, { width: vp.width, height: vp.height })
  const results = []

  await login(page, "customer")
  results.push({ step: "login", url: "/customer", note: "landed after login" })

  for (const p of STATIC_PAGES) {
    const r = await visitAndCapture(page, { url: p.url, outDir, name: p.name, consoleErrors })
    results.push(r)
  }

  if (deepModals) {
    // Language toggle
    await page.goto("http://localhost:5173/customer", { waitUntil: "networkidle" })
    const langBtn = page.locator('button[aria-haspopup], button:has-text("EN"), button:has-text("English")').first()
    try {
      await langBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await page.screenshot({ path: path.join(outDir, "12-language-menu-open.png"), fullPage: true })
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "language-menu", error: e.message })
    }

    // User menu
    try {
      const userMenuBtn = page.locator("header button:has(svg)").last()
      await userMenuBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await page.screenshot({ path: path.join(outDir, "13-user-menu-open.png"), fullPage: true })
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "user-menu", error: e.message })
    }

    // Booking detail via first booking row
    await page.goto("http://localhost:5173/customer/bookings", { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    const bookingRow = page.locator("[class*='cursor-pointer'], button, div[role='button']").filter({ hasText: /./ })
    const bookingClickable = page.locator("text=/./").first() // fallback, replaced below by a direct approach
    const firstBookingCard = page.locator("main >> css=[onclick], main button").first()
    // Simplify: BookingRow likely a div with onClick — query by role heuristics instead
    const rowCandidate = page.locator("main div.cursor-pointer, main > div > div").first()
    let reachedBookingDetail = false
    try {
      const anyCard = page.locator("main").locator("div").filter({ hasText: "₹" }).first()
      if (await anyCard.count() > 0) {
        await anyCard.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (page.url().includes("/customer/bookings/")) {
          reachedBookingDetail = true
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "14-booking-detail", consoleErrors })
          results.push(r)
        }
      }
    } catch (e) {
      results.push({ step: "booking-detail", error: e.message })
    }
    if (!reachedBookingDetail) {
      results.push({ step: "booking-detail", note: "Could not reliably click into a booking row (no bookings, or row isn't a simple clickable match) — not reached live." })
    }

    // AMC product detail via first AMC card
    await page.goto("http://localhost:5173/customer/amc", { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    const amcCard = page.locator("main button, main [class*='cursor-pointer']").first()
    if (await amcCard.count() > 0) {
      try {
        await amcCard.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (page.url().includes("/customer/amc/")) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "15-amc-product-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "amc-detail", note: "Click did not navigate to an AMC product detail — likely no AMC products for this test customer." })
        }
      } catch (e) {
        results.push({ step: "amc-detail", error: e.message })
      }
    } else {
      results.push({ step: "amc-detail", note: "No clickable AMC product card found." })
    }

    // Product catalog detail via first product tile
    await page.goto("http://localhost:5173/customer/product-enquiry", { waitUntil: "networkidle" })
    await page.waitForTimeout(800)
    const productTile = page.locator("main button, main [class*='cursor-pointer']").first()
    if (await productTile.count() > 0) {
      try {
        await productTile.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (page.url().includes("/catalog/")) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "16-product-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "product-detail", note: "Click did not navigate to a catalog product detail." })
        }
      } catch (e) {
        results.push({ step: "product-detail", error: e.message })
      }
    } else {
      results.push({ step: "product-detail", note: "No clickable product tile found in catalog." })
    }
  }

  await context.close()
  await browser.close()
  return results
}

const allResults = {}
for (const [key, deep] of [["mobile", true], ["tablet", true], ["desktop", false]]) {
  console.log(`=== Running ${key} ===`)
  allResults[key] = await run(key, { deepModals: deep })
}
writeLog(LOG_PATH, allResults)
console.log("DONE. Log at", LOG_PATH)
