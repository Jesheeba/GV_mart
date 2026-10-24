// Phase 2, Wave 3 — Admin all-staff + ops pages (operation_admin role covers both)
import { chromium } from "playwright"
import { WIDTHS, newContext, login, visitAndCapture, writeLog, shot } from "./audit-lib.mjs"
import path from "node:path"

const OUT_ROOT = path.resolve("ui-audit/screenshots/before/admin-ops")
const LOG_PATH = path.resolve("ui-audit/screenshots/before/admin-ops/_log.json")

const PAGES = [
  // All-staff
  { url: "/admin", name: "01-dashboard" },
  { url: "/admin/workspace", name: "02-workspace" },
  { url: "/admin/tasks", name: "03-tasks" },
  { url: "/admin/huddle", name: "04-huddle" },
  { url: "/admin/notifications", name: "05-notifications" },
  // Ops
  { url: "/admin/service", name: "06-service-tickets" },
  { url: "/admin/service/new", name: "07-new-complaint" },
  { url: "/admin/service/appointments", name: "08-appointments" },
  { url: "/admin/technicians", name: "09-technicians" },
  { url: "/admin/technicians/map", name: "10-technicians-map" },
  { url: "/admin/technicians/attendance", name: "11-technicians-attendance" },
  { url: "/admin/technicians/spares", name: "12-technicians-spares" },
  { url: "/admin/inventory", name: "13-inventory" },
  { url: "/admin/suppliers", name: "14-suppliers" },
  { url: "/admin/purchase", name: "15-purchase" },
  { url: "/admin/complaints", name: "16-complaints" },
  { url: "/admin/returns", name: "17-returns" },
]

async function run(widthKey, { deepModals }) {
  const vp = WIDTHS[widthKey]
  const outDir = path.join(OUT_ROOT, vp.name)
  const browser = await chromium.launch()
  const { context, page, consoleErrors } = await newContext(browser, { width: vp.width, height: vp.height })
  const results = []

  await login(page, "operation_admin")
  results.push({ step: "login", url: "/admin", note: "landed after login" })

  for (const p of PAGES) {
    const r = await visitAndCapture(page, { url: p.url, outDir, name: p.name, consoleErrors })
    results.push(r)
  }

  if (deepModals) {
    // User menu + global search dropdown on dashboard
    await page.goto("http://localhost:5173/admin", { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    try {
      const userMenuBtn = page.locator("header button:has(svg)").last()
      await userMenuBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await shot(page, outDir, "18-user-menu-open")
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "user-menu", error: e.message })
    }

    try {
      await page.fill("#admin-global-search", "a")
      await page.waitForTimeout(600)
      await shot(page, outDir, "19-global-search-open")
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "global-search", error: e.message })
    }

    // Open a service ticket detail via first row on the tickets list
    await page.goto("http://localhost:5173/admin/service", { waitUntil: "networkidle" })
    await page.waitForTimeout(600)
    const ticketRow = page.locator("table tbody tr, main [class*='cursor-pointer']").first()
    if (await ticketRow.count() > 0) {
      try {
        await ticketRow.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (/\/admin\/service\/[0-9a-f-]+$/.test(page.url())) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "20-ticket-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "ticket-detail", note: "Click did not navigate to a ticket detail URL." })
        }
      } catch (e) {
        results.push({ step: "ticket-detail", error: e.message })
      }
    } else {
      results.push({ step: "ticket-detail", note: "No clickable ticket row found." })
    }

    // Open a technician detail via first row
    await page.goto("http://localhost:5173/admin/technicians", { waitUntil: "networkidle" })
    await page.waitForTimeout(600)
    const techRow = page.locator("table tbody tr, main [class*='cursor-pointer']").first()
    if (await techRow.count() > 0) {
      try {
        await techRow.click({ timeout: 3000 })
        await page.waitForTimeout(600)
        if (/\/admin\/technicians\/[0-9a-f-]+$/.test(page.url())) {
          const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "21-technician-detail", consoleErrors })
          results.push(r)
        } else {
          results.push({ step: "technician-detail", note: "Click did not navigate to a technician detail URL." })
        }
      } catch (e) {
        results.push({ step: "technician-detail", error: e.message })
      }
    } else {
      results.push({ step: "technician-detail", note: "No clickable technician row found." })
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
