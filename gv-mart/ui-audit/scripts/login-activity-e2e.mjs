// Playwright E2E for HR → Login Activity (build-docs/features/login-activity.md). Credentials read from
// gv-mart/.env.test, never printed. Usage: node ui-audit/scripts/login-activity-e2e.mjs <worktree gv-mart dir> <base url> <out dir>
import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

const [root, BASE, OUT] = process.argv.slice(2)
const imp = (p) => import(pathToFileURL(path.join(root, "node_modules", p)).href)
const { chromium } = await imp("playwright/index.mjs")
const { default: AxeBuilder } = await imp("@axe-core/playwright/dist/index.mjs")
const { createClient } = await imp("@supabase/supabase-js/dist/index.mjs")

const env = (f) => Object.fromEntries(fs.readFileSync(f, "utf8").split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).trim().replace(/^"|"$/g, "")]))
const creds = env(path.join(root, "../../../../gv-mart/.env.test"))
const vite = env(path.join(root, ".env.local"))

const results = []
const check = (id, ok, detail = "") => { results.push(`${ok ? "ok  " : "FAIL"} ${id}${detail ? " — " + detail : ""}`) }
const shot = (page, name) => page.screenshot({ path: path.join(OUT, name), fullPage: true })

const browser = await chromium.launch()
const page = await (await browser.newContext({ viewport: { width: 1366, height: 900 } })).newPage()
const consoleErrors = []
page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()))

async function login(email, password) {
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", email)
  await page.fill("#password", password)
  await page.locator('button[type="submit"]').click()
  await page.waitForURL((u) => !u.pathname.includes("/login"), { timeout: 20000 })
}

const rowsLocator = () => page.locator("table tbody tr")
async function waitTable() {
  await page.waitForFunction(() => !document.querySelector("table tbody [data-slot=skeleton], table tbody .animate-pulse"), null, { timeout: 15000 }).catch(() => {})
  await page.waitForTimeout(800)
}

try {
  // AC1 live: this login itself must appear
  const loginAt = Date.now()
  await login(creds.MASTER_TEST_EMAIL, creds.MASTER_TEST_PASSWORD)
  await page.goto(`${BASE}/admin/hr`, { waitUntil: "networkidle" })
  await page.getByRole("tab", { name: "Login Activity" }).click()
  await waitTable()
  await shot(page, "01-login-activity-all.png")

  const headers = (await page.locator("table thead th").allInnerTexts()).map((s) => s.trim().toLowerCase())
  check("AC4 columns", ["name", "role", "login", "last active", "logout", "duration", "device"].every((h) => headers.includes(h)), headers.join(" | "))
  const n = await rowsLocator().count()
  check("AC4 rows listed", n > 0, `${n} rows on page 1`)
  const first = (await rowsLocator().first().innerText()).replace(/\s+/g, " ")
  check("AC1 my own fresh login is the newest row, signed in, Chrome · Windows", /Master/.test(first) && /Signed in/.test(first) && /Chrome · Windows|Chromium|Chrome/.test(first), first)
  const pageInfo = await page.getByText(/Page \d+ of \d+/).innerText().catch(() => "")
  check("AC5 page info shown", /Page 1 of \d+ · \d+ logins/.test(pageInfo), pageInfo)

  // AC5 role filters
  for (const [chip, role] of [["Staff", /Master|Operations Admin|Sales Admin/], ["Technicians", /Technician/], ["Customers", /Customer/]]) {
    await page.getByRole("button", { name: chip, exact: true }).click()
    await waitTable()
    const texts = await rowsLocator().allInnerTexts()
    const empty = texts.length === 1 && /No logins in this period/.test(texts[0])
    const allMatch = empty || texts.every((t) => role.test(t))
    check(`AC5 role chip ${chip}`, allMatch, empty ? "empty state" : `${texts.length} rows, all ${chip}`)
    await shot(page, `02-filter-${chip.toLowerCase()}.png`)
  }
  await page.getByRole("button", { name: "All", exact: true }).click()
  await waitTable()

  // AC5 search (no match → empty state, then clear)
  await page.fill("#login-search", "zzz-no-such-user-zzz")
  await waitTable()
  check("AC5 search no-match → empty state", await page.getByText("No logins in this period.").isVisible())
  await page.fill("#login-search", "")
  await waitTable()

  // Edge: invalid range → alert, no fetch
  await page.fill("#login-from", "2024-01-01")
  await waitTable()
  check("Edge range > 366 days shows validation message", await page.getByRole("alert").isVisible())
  await shot(page, "03-invalid-range.png")
  await page.fill("#login-from", new Date(Date.now() - 6 * 86400000).toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" }))
  await waitTable()

  // AC8 other HR tabs still render
  for (const tab of ["Salary", "Incentives", "Rewards"]) {
    await page.getByRole("tab", { name: tab, exact: true }).click()
    await page.waitForTimeout(600)
    check(`AC8 HR tab ${tab} still opens`, (await page.getByRole("tabpanel").count()) > 0)
  }
  await page.getByRole("tab", { name: "Login Activity" }).click()
  await waitTable()

  // Accessibility scan of the tab
  const axe = await new AxeBuilder({ page }).include('[role="tabpanel"]').withTags(["wcag2a", "wcag2aa"]).analyze()
  const serious = axe.violations.filter((v) => ["serious", "critical"].includes(v.impact))
  check("A11y no serious/critical axe violations in tab", serious.length === 0, serious.map((v) => `${v.id}(${v.nodes.length})`).join(", "))

  // Mobile width
  await page.setViewportSize({ width: 390, height: 844 })
  await page.waitForTimeout(500)
  await shot(page, "04-mobile.png")
  await page.setViewportSize({ width: 1366, height: 900 })

  // AC2 sign out → ended_at; verify via RPC as master from a separate client
  await page.goto(`${BASE}/admin`, { waitUntil: "networkidle" })
  await page.locator("header button").filter({ has: page.locator("img, span") }).last().click()
  await page.getByRole("menuitem", { name: /sign out/i }).click()
  await page.waitForURL((u) => u.pathname.includes("/login"), { timeout: 15000 })
  const sb = createClient(vite.VITE_SUPABASE_URL, vite.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } })
  await sb.auth.signInWithPassword({ email: creds.MASTER_TEST_EMAIL, password: creds.MASTER_TEST_PASSWORD })
  const today = new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Kolkata" })
  const { data: mine, error: e1 } = await sb.rpc("list_login_activity", { p_from: today, p_to: today, p_role: "staff", p_search: null, p_limit: 200, p_offset: 0 })
  const browserSession = (mine ?? []).filter((r) => Date.parse(r.started_at) >= loginAt - 60000 && /Chrome/.test(r.user_agent ?? ""))
  check("AC2 browser sign-out recorded ended_at", !e1 && browserSession.length >= 1 && browserSession.every((r) => r.ended_at), e1?.message ?? `${browserSession.length} browser session(s)`)
  check("AC1 API login also captured (no UA browser)", (mine ?? []).some((r) => Date.parse(r.started_at) >= loginAt && r.ended_at === null))
  await sb.auth.signOut()

  // AC6 technician: UI blocked + RPC rejected
  await login(creds.TECHNICIAN_TEST_EMAIL, creds.TECHNICIAN_TEST_PASSWORD)
  await page.goto(`${BASE}/admin/hr`, { waitUntil: "networkidle" })
  const onHr = new URL(page.url()).pathname === "/admin/hr" && (await page.getByRole("tab", { name: "Login Activity" }).count()) > 0
  check("AC6 technician cannot open HR", !onHr, `landed on ${new URL(page.url()).pathname}`)
  await shot(page, "05-technician-blocked.png")
  const tc = createClient(vite.VITE_SUPABASE_URL, vite.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } })
  await tc.auth.signInWithPassword({ email: creds.TECHNICIAN_TEST_EMAIL, password: creds.TECHNICIAN_TEST_PASSWORD })
  const { data: td, error: te } = await tc.rpc("list_login_activity", { p_from: today, p_to: today, p_role: "all", p_search: null, p_limit: 50, p_offset: 0 })
  check("AC6 technician RPC rejected", !!te && !td, te?.code ?? "no error")
  const { error: de } = await tc.from("login_sessions").select("session_id").limit(1)
  check("AC6 technician direct table select denied", !!de, de?.code ?? "no error")
  await tc.auth.signOut()

  // AC6 anon
  const an = createClient(vite.VITE_SUPABASE_URL, vite.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } })
  const { error: ae } = await an.rpc("list_login_activity", { p_from: today, p_to: today, p_role: "all", p_search: null, p_limit: 50, p_offset: 0 })
  check("AC6 anon RPC rejected", !!ae, ae?.code ?? "no error")

  const relevant = consoleErrors.filter((e) => /login_activity|LoginActivity|list_login/i.test(e))
  check("No console errors from the feature", relevant.length === 0, relevant.slice(0, 2).join(" / "))
} catch (e) {
  check("script", false, String(e?.message ?? e).split("\n")[0])
  await shot(page, "99-error.png").catch(() => {})
} finally {
  await browser.close()
  console.log(results.join("\n"))
}
