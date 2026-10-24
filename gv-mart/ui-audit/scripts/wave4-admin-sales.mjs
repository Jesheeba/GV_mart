// Phase 2, Wave 4 — Admin sales pages (sales_admin role)
import { chromium } from "playwright"
import { WIDTHS, newContext, login, visitAndCapture, writeLog, shot } from "./audit-lib.mjs"
import path from "node:path"

const OUT_ROOT = path.resolve("ui-audit/screenshots/before/admin-sales")
const LOG_PATH = path.resolve("ui-audit/screenshots/before/admin-sales/_log.json")

const PAGES = [
  { url: "/admin/my-day", name: "01-my-day" },
  { url: "/admin/customers", name: "02-customers" },
  { url: "/admin/customers/new", name: "03-new-customer" },
  { url: "/admin/sales", name: "04-sales" },
  { url: "/admin/sales/new", name: "05-new-sale" },
  { url: "/admin/quotations", name: "06-quotations" },
  { url: "/admin/quotations/new", name: "07-new-quotation" },
  { url: "/admin/leads", name: "08-leads" },
  { url: "/admin/automation", name: "09-automation" },
  { url: "/admin/rentals", name: "10-rentals" },
  { url: "/admin/campaigns", name: "11-campaigns" },
]

async function run(widthKey, { deepModals }) {
  const vp = WIDTHS[widthKey]
  const outDir = path.join(OUT_ROOT, vp.name)
  const browser = await chromium.launch()
  const { context, page, consoleErrors } = await newContext(browser, { width: vp.width, height: vp.height })
  const results = []

  await login(page, "sales_admin")
  results.push({ step: "login", url: "/admin/my-day", note: "landed after login" })

  for (const p of PAGES) {
    const r = await visitAndCapture(page, { url: p.url, outDir, name: p.name, consoleErrors })
    results.push(r)
  }

  if (deepModals) {
    // Customer detail via first row
    await page.goto("http://localhost:5173/admin/customers", { waitUntil: "networkidle" })
    await page.waitForTimeout(600)
    const custRow = page.locator("table tbody tr, main [class*='cursor-pointer']").first()
    if (await custRow.count() > 0) {
      try {
        await custRow.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (/\/admin\/customers\/[0-9a-f-]+$/.test(page.url())) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "12-customer-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "customer-detail", note: "Click did not navigate to a customer detail URL." })
        }
      } catch (e) {
        results.push({ step: "customer-detail", error: e.message })
      }
    } else {
      results.push({ step: "customer-detail", note: "No clickable customer row found." })
    }

    // Lead detail via first card
    await page.goto("http://localhost:5173/admin/leads", { waitUntil: "networkidle" })
    await page.waitForTimeout(600)
    const leadCard = page.locator("main [class*='cursor-pointer'], main button").first()
    if (await leadCard.count() > 0) {
      try {
        await leadCard.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (/\/admin\/leads\/[0-9a-f-]+$/.test(page.url())) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "13-lead-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "lead-detail", note: "Click did not navigate to a lead detail URL." })
        }
      } catch (e) {
        results.push({ step: "lead-detail", error: e.message })
      }
    } else {
      results.push({ step: "lead-detail", note: "No clickable lead card found." })
    }

    // User menu
    await page.goto("http://localhost:5173/admin/my-day", { waitUntil: "networkidle" })
    try {
      const userMenuBtn = page.locator("header button:has(svg)").last()
      await userMenuBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await shot(page, outDir, "14-user-menu-open")
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "user-menu", error: e.message })
    }
  }

  await context.close()
  await browser.close()
  return results
}

const allResults = {}
for (const [key, deep] of [["desktop", true], ["laptop", true], ["tablet", false]]) {
  console.log(`=== Running ${key} ===`)
  allResults[key] = await run(key, { deepModals: deep })
}
writeLog(LOG_PATH, allResults)
console.log("DONE. Log at", LOG_PATH)
