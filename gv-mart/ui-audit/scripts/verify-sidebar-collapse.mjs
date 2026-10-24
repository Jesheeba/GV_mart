// Verifies the collapsible admin sidebar (label-beside-icon, collapse
// toggle, remembered state, tooltips when collapsed) at phone widths.
// Not part of the app build — lives under ui-audit/ only.
import { chromium } from "playwright"
import { ensureDir, CREDS, PASSWORD } from "./audit-lib.mjs"
import path from "node:path"

const BASE_URL = "http://localhost:5174"
const OUT_DIR = "ui-audit/screenshots/sidebar-collapse"
const WIDTHS = [
  { width: 360, height: 740, name: "360" },
  { width: 375, height: 812, name: "375" },
]

async function login(page) {
  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", CREDS.master)
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})
}

;(async () => {
  ensureDir(OUT_DIR)
  const browser = await chromium.launch()
  const results = {}

  for (const vp of WIDTHS) {
    const context = await browser.newContext({ viewport: { width: vp.width, height: vp.height } })
    const page = await context.newPage()
    const errors = []
    page.on("console", (m) => {
      if (m.type() === "error") errors.push(m.text())
    })
    page.on("pageerror", (err) => errors.push("PAGEERROR: " + err.message))

    // Fresh localStorage per viewport — no stale collapse preference from a
    // prior run leaking into this one.
    await page.goto(`${BASE_URL}/login`)
    await page.evaluate(() => localStorage.removeItem("gv_mart_admin_sidebar_collapsed"))
    await login(page)
    await page.waitForTimeout(600)

    // 1) First load at this width, no saved preference — should default to
    // collapsed (icon-only) so the sidebar doesn't eat the screen.
    const asideWidthCollapsed = await page.locator("aside").first().evaluate((el) => el.getBoundingClientRect().width)
    await page.screenshot({ path: path.join(OUT_DIR, `${vp.name}-collapsed.png`) })

    // Tooltip-on-hover check (collapsed) — hover the active nav item's icon.
    const activeLink = page.locator("aside nav a.bg-ink, aside nav a[aria-current='page']").first()
    const activeCount = await activeLink.count()
    let tooltipVisibleOnHover = null
    if (activeCount > 0) {
      await activeLink.hover()
      await page.waitForTimeout(250)
      // Portalled to <body> (not a descendant of the link) so it can escape
      // the sidebar's own overflow clipping — see AdminShell.tsx.
      const tooltip = page.locator("body > [role='tooltip']")
      tooltipVisibleOnHover = (await tooltip.count()) > 0 ? await tooltip.isVisible() : false
      await page.screenshot({ path: path.join(OUT_DIR, `${vp.name}-collapsed-tooltip.png`) })
    }

    // 2) Expand via the toggle.
    const toggle = page.getByRole("button", { name: /expand sidebar/i })
    await toggle.click()
    await page.waitForTimeout(350) // let the width transition settle
    const asideWidthExpanded = await page.locator("aside").first().evaluate((el) => el.getBoundingClientRect().width)
    const labelsVisible = await page.locator("aside nav a span.truncate").first().isVisible()
    await page.screenshot({ path: path.join(OUT_DIR, `${vp.name}-expanded.png`) })

    // 3) Reload — the choice should be remembered (still expanded).
    await page.reload({ waitUntil: "networkidle" })
    await page.waitForTimeout(400)
    const asideWidthAfterReload = await page.locator("aside").first().evaluate((el) => el.getBoundingClientRect().width)
    const stillExpandedAfterReload = asideWidthAfterReload > 100

    results[vp.name] = {
      asideWidthCollapsed,
      asideWidthExpanded,
      collapsedIsNarrow: asideWidthCollapsed < 100,
      labelsVisibleWhenExpanded: labelsVisible,
      stillExpandedAfterReload,
      tooltipVisibleOnHoverWhenCollapsed: tooltipVisibleOnHover,
      consoleErrors: errors.slice(0, 5),
    }

    await context.close()
  }

  console.log(JSON.stringify(results, null, 2))
  await browser.close()
})()
