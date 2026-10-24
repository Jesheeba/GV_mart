// Phase 2, Wave 5 — Admin master-only pages (master role)
import { chromium } from "playwright"
import { WIDTHS, newContext, login, visitAndCapture, writeLog, shot, runAxe } from "./audit-lib.mjs"
import path from "node:path"

const OUT_ROOT = path.resolve("ui-audit/screenshots/before/admin-master")
const LOG_PATH = path.resolve("ui-audit/screenshots/before/admin-master/_log.json")

const PAGES = [
  { url: "/admin/amc", name: "01-amc-warranty" },
  { url: "/admin/hr", name: "02-hr" },
  { url: "/admin/accounts", name: "03-accounts" },
  { url: "/admin/reports", name: "04-reports" },
  { url: "/admin/masters", name: "05-masters-products" },
  { url: "/admin/approvals", name: "06-approvals" },
  { url: "/admin/audit-log", name: "07-audit-log" },
]

// Full audit: distinct-layout tabs. Spot-check: generic EntityCrudTable tabs.
const MASTERS_TABS_FULL = ["AMC Plans", "Technician Tiers", "Settings", "Payment Settings", "Water Quality (TDS)", "Activities"]
const MASTERS_TABS_SPOT = ["Brands", "Gift Exclusions", "Lead Outcomes"]

async function run(widthKey, { deepModals }) {
  const vp = WIDTHS[widthKey]
  const outDir = path.join(OUT_ROOT, vp.name)
  const browser = await chromium.launch()
  const { context, page, consoleErrors } = await newContext(browser, { width: vp.width, height: vp.height })
  const results = []

  await login(page, "master")
  results.push({ step: "login", url: "/admin", note: "landed after login" })

  for (const p of PAGES) {
    const r = await visitAndCapture(page, { url: p.url, outDir, name: p.name, consoleErrors })
    results.push(r)
  }

  if (deepModals) {
    // Masters sub-tabs — full audit list
    let idx = 8
    for (const label of MASTERS_TABS_FULL) {
      try {
        await page.goto("http://localhost:5173/admin/masters", { waitUntil: "networkidle" })
        await page.waitForTimeout(400)
        const tabBtn = page.locator("button h3", { hasText: label }).getByText(label, { exact: true }).locator("xpath=ancestor::button[1]")
        await tabBtn.click({ timeout: 4000 })
        await page.waitForLoadState("networkidle").catch(() => {}); await page.waitForTimeout(1200)
        const name = `${String(idx).padStart(2, "0")}-masters-${label.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`
        await shot(page, outDir, name)
        const axe = await runAxe(page)
        results.push({ name: `masters-${label}`, axeViolations: axe })
        idx++
      } catch (e) {
        results.push({ step: `masters-tab-${label}`, error: e.message })
      }
    }
    // Spot-check tabs — screenshot only, lighter check
    for (const label of MASTERS_TABS_SPOT) {
      try {
        await page.goto("http://localhost:5173/admin/masters", { waitUntil: "networkidle" })
        await page.waitForTimeout(400)
        const tabBtn = page.locator("button h3", { hasText: label }).getByText(label, { exact: true }).locator("xpath=ancestor::button[1]")
        await tabBtn.click({ timeout: 4000 })
        await page.waitForLoadState("networkidle").catch(() => {}); await page.waitForTimeout(1200)
        const name = `${String(idx).padStart(2, "0")}-masters-spotcheck-${label.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`
        await shot(page, outDir, name)
        idx++
      } catch (e) {
        results.push({ step: `masters-spotcheck-${label}`, error: e.message })
      }
    }

    // AMC contract detail via first row
    await page.goto("http://localhost:5173/admin/amc", { waitUntil: "networkidle" })
    await page.waitForTimeout(600)
    const amcRow = page.locator("table tbody tr, main [class*='cursor-pointer']").first()
    if (await amcRow.count() > 0) {
      try {
        await amcRow.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (/\/admin\/amc\/[0-9a-f-]+$/.test(page.url())) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: `${idx}-amc-contract-detail`, consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "amc-detail", note: "Click did not navigate to an AMC contract detail URL." })
        }
      } catch (e) {
        results.push({ step: "amc-detail", error: e.message })
      }
    } else {
      results.push({ step: "amc-detail", note: "No clickable AMC row found." })
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
