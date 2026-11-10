// Shared helpers for the GV Mart UI audit scripts (Phase 2).
// Not part of the app build — lives under ui-audit/ only.
import { chromium } from "playwright"
import AxeBuilder from "@axe-core/playwright"
import fs from "node:fs"
import path from "node:path"

export const BASE_URL = "http://localhost:5173"
export const CREDS = {
  master: "master@gvmart.test",
  operation_admin: "operation_admin@gvmart.test",
  sales_admin: "sales_admin@gvmart.test",
  technician: "technician@gvmart.test",
  customer: "customer@gvmart.test",
}

// The password is a credential, not a fixture -- it must never sit in
// source, even for a test-only local Supabase account. Every ui-audit
// script imports PASSWORD from here, so gating it at this one import site
// makes every one of them refuse to run (fail at import, before any browser
// or network action) when UI_AUDIT_PASSWORD isn't set, with no fallback.
export const PASSWORD = process.env.UI_AUDIT_PASSWORD
if (!PASSWORD) {
  throw new Error(
    "UI_AUDIT_PASSWORD is not set. Export it before running any ui-audit script " +
      "(e.g. `export UI_AUDIT_PASSWORD=$(grep '^MASTER_TEST_PASSWORD=' .env.test | cut -d= -f2-)`, " +
      "since every demo role here shares one password)."
  )
}

export const WIDTHS = {
  mobile: { width: 375, height: 812, name: "375" },
  tablet: { width: 768, height: 1024, name: "768" },
  laptop: { width: 1024, height: 800, name: "1024" },
  desktop: { width: 1440, height: 900, name: "1440" },
}

export function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true })
}

export async function newContext(browser, viewport) {
  const context = await browser.newContext({ viewport })
  const page = await context.newPage()
  const consoleErrors = []
  page.on("console", (msg) => {
    if (msg.type() === "error") consoleErrors.push(msg.text())
  })
  page.on("pageerror", (err) => consoleErrors.push("PAGEERROR: " + err.message))
  return { context, page, consoleErrors }
}

export async function login(page, role) {
  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", CREDS[role])
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})
}

export async function shot(page, outDir, name) {
  ensureDir(outDir)
  // AdminShell locks document.body/html to the viewport (`h-screen overflow-hidden`)
  // and scrolls inside its own <main> instead — a plain `fullPage: true` screenshot
  // silently truncates to one viewport-tall slice on every admin page, and an element
  // screenshot of <main> only grabs its clipped clientHeight, not its full
  // scrollHeight. Work around both by temporarily forcing every scroll-locked
  // ancestor (and <main> itself) to flow naturally, so the whole page becomes one
  // tall document fullPage can capture — then restore the inline styles we touched.
  const touched = await page.evaluate(() => {
    const changed = []
    let el = document.querySelector("main")
    while (el) {
      const cs = getComputedStyle(el)
      if (cs.overflow === "hidden" || cs.overflowY === "auto" || cs.overflowY === "scroll" || cs.height !== "auto") {
        changed.push({ el, overflow: el.style.overflow, overflowY: el.style.overflowY, height: el.style.height })
        el.style.overflow = "visible"
        el.style.overflowY = "visible"
        el.style.height = "auto"
      }
      el = el.parentElement
    }
    return changed.length
  })
  await page.waitForTimeout(touched > 0 ? 150 : 0)
  await page.screenshot({ path: path.join(outDir, `${name}.png`), fullPage: true })
  if (touched > 0) {
    await page.evaluate(() => {
      // best-effort: reload-free restore isn't tracked across the evaluate boundary,
      // so just reload the current state on next navigation instead of trying to
      // hand back element refs here (each visitAndCapture call navigates fresh anyway).
    })
  }
}

export async function runAxe(page) {
  const results = await new AxeBuilder({ page }).analyze()
  return results.violations.map((v) => ({
    id: v.id,
    impact: v.impact,
    help: v.help,
    nodes: v.nodes.length,
    targets: v.nodes.slice(0, 3).map((n) => n.target.join(" ")),
  }))
}

export async function visitAndCapture(page, { url, outDir, name, consoleErrors, waitSelector, beforeShot }) {
  consoleErrors.length = 0
  let navError = null
  try {
    await page.goto(`${BASE_URL}${url}`, { waitUntil: "networkidle", timeout: 20000 })
  } catch (e) {
    navError = e.message
  }
  if (waitSelector) {
    await page.waitForSelector(waitSelector, { timeout: 8000 }).catch(() => {})
  }
  await page.waitForTimeout(400)
  if (beforeShot) await beforeShot(page)
  await shot(page, outDir, name)
  const axe = await runAxe(page).catch((e) => [{ id: "axe-failed", impact: "n/a", help: e.message, nodes: 0, targets: [] }])
  return {
    url,
    name,
    navError,
    consoleErrors: [...consoleErrors],
    axeViolations: axe,
  }
}

export function writeLog(filePath, data) {
  ensureDir(path.dirname(filePath))
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2))
}
