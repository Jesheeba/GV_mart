// Phase 2, Wave 1 — Technician area capture (screenshots + console errors + axe)
import { chromium } from "playwright"
import { WIDTHS, newContext, login, visitAndCapture, writeLog } from "./audit-lib.mjs"
import path from "node:path"

const OUT_ROOT = path.resolve("ui-audit/screenshots/before/technician")
const LOG_PATH = path.resolve("ui-audit/screenshots/before/technician/_log.json")

const STATIC_PAGES = [
  { url: "/technician", name: "01-home" },
  { url: "/technician/map", name: "02-map" },
  { url: "/technician/attendance", name: "03-attendance" },
  { url: "/technician/history", name: "04-history" },
  { url: "/technician/profile", name: "05-profile" },
  { url: "/technician/spares", name: "06-spares" },
  { url: "/technician/spares/history", name: "07-spares-history" },
  { url: "/technician/search", name: "08-search" },
  { url: "/technician/day-sheet", name: "09-day-sheet" },
  { url: "/technician/notifications", name: "10-notifications" },
  { url: "/technician/tasks", name: "11-tasks" },
  { url: "/technician/huddle", name: "12-huddle" },
]

async function run(widthKey, { deepModals }) {
  const vp = WIDTHS[widthKey]
  const outDir = path.join(OUT_ROOT, vp.name)
  const browser = await chromium.launch()
  const { context, page, consoleErrors } = await newContext(browser, { width: vp.width, height: vp.height })
  const results = []

  await login(page, "technician")
  results.push({ step: "login", url: "/technician", note: "landed after login" })

  for (const p of STATIC_PAGES) {
    const r = await visitAndCapture(page, { url: p.url, outDir, name: p.name, consoleErrors })
    results.push(r)
  }

  if (deepModals) {
    // Overflow menu (theme + language) in header
    await page.goto("http://localhost:5173/technician", { waitUntil: "networkidle" })
    const overflowBtn = page.locator('button[aria-label*="More" i], button[aria-haspopup="menu"]').first()
    try {
      await overflowBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await page.screenshot({ path: path.join(outDir, "13-overflow-menu-open.png"), fullPage: true })
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "overflow-menu", error: e.message })
    }

    // User menu
    try {
      const userMenuBtn = page.locator('button:has-text("Technician"), header button img, header button:has(svg)').last()
      await userMenuBtn.click({ timeout: 3000 })
      await page.waitForTimeout(300)
      await page.screenshot({ path: path.join(outDir, "14-user-menu-open.png"), fullPage: true })
      await page.keyboard.press("Escape")
    } catch (e) {
      results.push({ step: "user-menu", error: e.message })
    }

    // Try to reach a real job detail page via the first job card on Home
    await page.goto("http://localhost:5173/technician", { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    const jobCard = page.locator("button.block.w-full.text-left").first()
    if (await jobCard.count() > 0) {
      await jobCard.click()
      await page.waitForTimeout(600)
      const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "15-job-detail", consoleErrors })
      results.push(r)

      // Check whether "Start Visit" exists (openVisit already true) — only then is it
      // safe to view the on-site stepper's first screen without writing any data
      // (the alternative "confirm arrival" CTA starts a real DB-backed visit — skipped).
      const startVisitBtn = page.locator('button:has-text("Visit")').first()
      if (await startVisitBtn.count() > 0 && (await startVisitBtn.textContent())?.toLowerCase().includes("start")) {
        await startVisitBtn.click()
        await page.waitForTimeout(600)
        const rv = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "16-onsite-visit-step1", consoleErrors })
        results.push(rv)
      } else {
        results.push({ step: "onsite-visit", note: "No open visit for test technician's first job — 'Start Visit' not available. Confirming arrival would write a real service_visits row, so this was skipped per audit rules (data-write boundary). Audited from code read only." })
      }

      // Route view (safe — read-only map display keyed off the customer-name link)
      await page.goto(`http://localhost:5173${page.url().replace("http://localhost:5173", "").split("/visit")[0].split("/jobs")[0]}`, { waitUntil: "networkidle" }).catch(() => {})
    } else {
      results.push({ step: "job-detail", note: "No jobs on technician home list for this width/session — could not reach Job Detail/Route/On-Site Visit live. Audited from code read only." })
    }

    // History detail via first history card
    await page.goto("http://localhost:5173/technician/history", { waitUntil: "networkidle" })
    await page.waitForTimeout(500)
    const historyCard = page.locator("button.block.w-full.text-left").first()
    if (await historyCard.count() > 0) {
      await historyCard.click()
      await page.waitForTimeout(600)
      const r = await visitAndCapture(page, { url: page.url().replace("http://localhost:5173", ""), outDir, name: "17-history-detail", consoleErrors })
      results.push(r)
    } else {
      results.push({ step: "history-detail", note: "No history entries for test technician — could not reach History Detail live." })
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
