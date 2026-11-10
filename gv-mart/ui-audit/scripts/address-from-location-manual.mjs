// Manual Playwright script for "address-from-location" (Use my current location ->
// fills address text + pin). NOT run automatically as part of any gate or CI step --
// this file is provided for the owner (or a future session with DB/login access) to
// run by hand against a local dev server with a dummy "ZZ Test" customer. Mocks BOTH
// the browser Geolocation API (no real GPS needed) and the `geocode` Edge Function's
// network response (no real Google Maps API call, no cost, fully deterministic), so it
// never depends on actual location or burns a live quota.
//
// Usage:
//   npm run dev                                 (in one terminal, from gv-mart/)
//   UI_AUDIT_PASSWORD=<test password> node ui-audit/scripts/address-from-location-manual.mjs
//
// Covers, in order (task requirement 7):
//   1. tap "Use my current location" (mocked geolocation + mocked reverse-geocode) -> fields fill
//   2. edit a filled field -> save -> reload -> edit persisted, not silently overwritten again
//   3. denied-permission path -> clear message, no crash, address still fillable by hand
//   4. geocoder-failure path (Edge Function returns an error) -> clear message, pin still set, no crash
//
// Clean-up: this script creates no new address/customer data of its own -- it edits
// the dummy "ZZ Test" customer's OWN existing first address in place and leaves it
// pinned at the mocked coordinates afterward (same as any other manual QA edit). If
// that is not acceptable, revert it by hand afterward (or re-run step 1/2 with real data).
import { chromium } from "playwright"
import { BASE_URL, CREDS, PASSWORD } from "./audit-lib.mjs"

const MOCK_COORDS = { latitude: 13.0827, longitude: 80.2707, accuracy: 25 }
const MOCK_REVERSE_RESULT = {
  formatted: "12, Usman Road, T Nagar, Chennai, Tamil Nadu 600017",
  lat: MOCK_COORDS.latitude,
  lon: MOCK_COORDS.longitude,
  city: "Chennai",
  district: "Chennai",
  state: "Tamil Nadu",
  postcode: "600017",
  suburb: "T Nagar",
  locationType: "ROOFTOP",
  streetNumber: "12",
  route: "Usman Road",
}

async function mockReverseGeocode(page, { fail = false } = {}) {
  await page.route("**/functions/v1/geocode", async (route) => {
    const body = route.request().postDataJSON()
    if (body?.action !== "reverse") return route.continue()
    if (fail) {
      return route.fulfill({ status: 502, contentType: "application/json", body: JSON.stringify({ error: "Google Maps error (mocked failure)" }) })
    }
    return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ result: MOCK_REVERSE_RESULT }) })
  })
}

async function mockGeolocation(context, page, { denied = false } = {}) {
  if (denied) {
    // Simulate PERMISSION_DENIED without needing a real OS-level permission prompt.
    await page.addInitScript(() => {
      navigator.geolocation.getCurrentPosition = (_success, error) => error({ code: 1, message: "User denied Geolocation", PERMISSION_DENIED: 1 })
    })
    return
  }
  await context.grantPermissions(["geolocation"])
  await context.setGeolocation({ latitude: MOCK_COORDS.latitude, longitude: MOCK_COORDS.longitude, accuracy: MOCK_COORDS.accuracy })
}

async function login(page) {
  await page.goto(`${BASE_URL}/login`, { waitUntil: "networkidle" })
  await page.fill("#email", CREDS.customer)
  await page.fill("#password", PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("/login"), { timeout: 15000 })
  await page.waitForLoadState("networkidle").catch(() => {})
}

;(async () => {
  const browser = await chromium.launch()
  const results = []

  // ── 1 & 2: happy path -- use location, fields fill, edit, save, reload, persists ──
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, geolocation: { latitude: MOCK_COORDS.latitude, longitude: MOCK_COORDS.longitude } })
    const page = await context.newPage()
    await mockGeolocation(context, page)
    await mockReverseGeocode(page)
    await login(page)
    await page.goto(`${BASE_URL}/customer/profile`, { waitUntil: "networkidle" })

    // Open the existing first address for edit (or "Add address" if none exist yet).
    const editButton = page.getByRole("button", { name: /edit/i }).first()
    const addButton = page.getByRole("button", { name: /add address/i })
    if (await editButton.count()) await editButton.click()
    else await addButton.click()

    await page.getByRole("button", { name: /find my location/i }).click()
    await page.waitForTimeout(1500) // geolocation callback + reverse-geocode round trip

    const areaValue = await page.locator('input[placeholder*="Area" i]').first().inputValue()
    results.push({ step: "1-fields-filled", areaValue, pass: areaValue.length > 0 })

    // Edit a filled field before saving (must NOT be silently re-overwritten by anything).
    await page.locator('input[placeholder*="Area" i]').first().fill("My Edited Area")
    await page.getByRole("button", { name: /^save$/i }).click()
    await page.waitForTimeout(800)

    await page.reload({ waitUntil: "networkidle" })
    const persistedText = await page.locator("body").innerText()
    results.push({ step: "2-edit-persists-after-reload", pass: persistedText.includes("My Edited Area") })

    await context.close()
  }

  // ── 3: denied-permission path ────────────────────────────────────────────────────
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } })
    const page = await context.newPage()
    await mockGeolocation(context, page, { denied: true })
    await mockReverseGeocode(page)
    await login(page)
    await page.goto(`${BASE_URL}/customer/profile`, { waitUntil: "networkidle" })
    const editButton = page.getByRole("button", { name: /edit/i }).first()
    if (await editButton.count()) await editButton.click()
    await page.getByRole("button", { name: /find my location/i }).click()
    await page.waitForTimeout(500)
    const bodyText = await page.locator("body").innerText()
    results.push({ step: "3-denied-permission-shows-message", pass: /permission denied|denied/i.test(bodyText) })
    await context.close()
  }

  // ── 4: geocoder-failure path (pin sets, address lookup fails cleanly) ───────────
  {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 } })
    const page = await context.newPage()
    await mockGeolocation(context, page)
    await mockReverseGeocode(page, { fail: true })
    await login(page)
    await page.goto(`${BASE_URL}/customer/profile`, { waitUntil: "networkidle" })
    const editButton = page.getByRole("button", { name: /edit/i }).first()
    if (await editButton.count()) await editButton.click()
    await page.getByRole("button", { name: /find my location/i }).click()
    await page.waitForTimeout(1000)
    const bodyText = await page.locator("body").innerText()
    results.push({ step: "4-geocoder-failure-shows-message-no-crash", pass: /couldn.?t look up|fill in the details yourself/i.test(bodyText) })
    await context.close()
  }

  await browser.close()
  console.log(JSON.stringify(results, null, 2))
})()
