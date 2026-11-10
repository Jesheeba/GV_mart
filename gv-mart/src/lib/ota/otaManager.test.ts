import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

vi.mock("@capacitor/core", () => ({ Capacitor: { isNativePlatform: vi.fn(() => false) } }))
vi.mock("@capacitor/app", () => ({ App: { getInfo: vi.fn(), addListener: vi.fn() } }))
vi.mock("@capgo/capacitor-updater", () => ({
  CapacitorUpdater: { download: vi.fn(), next: vi.fn(), notifyAppReady: vi.fn(), current: vi.fn() },
}))
vi.mock("./storeUpdateGate", () => ({ setStoreUpdateRequired: vi.fn() }))

const { checkForOtaUpdate, notifyOtaAppReady, getOtaVersionInfo } = await import("./otaManager")
const { CapacitorUpdater } = await import("@capgo/capacitor-updater")
const { Capacitor } = await import("@capacitor/core")
const { App: CapacitorAppMock } = await import("@capacitor/app")
const { setStoreUpdateRequired } = await import("./storeUpdateGate")

describe("ota on the web build", () => {
  it("checkForOtaUpdate never touches the network or the updater on web", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")
    const result = await checkForOtaUpdate()
    expect(result).toEqual({ status: "skipped-web" })
    expect(fetchSpy).not.toHaveBeenCalled()
    expect(CapacitorUpdater.download).not.toHaveBeenCalled()
    expect(CapacitorUpdater.next).not.toHaveBeenCalled()
    fetchSpy.mockRestore()
  })

  it("notifyOtaAppReady is a no-op on web", async () => {
    await notifyOtaAppReady()
    expect(CapacitorUpdater.notifyAppReady).not.toHaveBeenCalled()
  })

  it("getOtaVersionInfo resolves null on web (so the version card never renders)", async () => {
    expect(await getOtaVersionInfo()).toBeNull()
  })

  it("the web build never hits /ota/ at all, across the whole module's native-gated surface", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")
    await Promise.all([checkForOtaUpdate(), notifyOtaAppReady(), getOtaVersionInfo()])
    const otaUrlCalls = fetchSpy.mock.calls.filter(([url]) => String(url).includes("/ota/"))
    expect(otaUrlCalls).toEqual([])
    fetchSpy.mockRestore()
  })
})

/**
 * Prompted by 2026-10-29's live check of the (never-published) production
 * channel: https://gv-mart.vercel.app/ota/production/manifest.json returns
 * HTTP 200 with the SPA's index.html (Vercel's client-routing fallback for
 * any unmatched path), not a real manifest or a 404. These tests exercise
 * the actual native code path (no mocking of fetch's result shape, no
 * mocking of verifyManifestSignature -- that's the real crypto check) to
 * prove checkForOtaUpdate treats that response, a genuinely offline fetch,
 * and a validly-shaped-but-wrongly-signed manifest all the same way:
 * resolves (never throws to the caller, so main.tsx's bare `void
 * checkForOtaUpdate()` can never surface an unhandled rejection or crash
 * the app), never calls CapacitorUpdater.download/next (a bad response can
 * never replace a working bundle), and never flips the StoreUpdateGate open
 * (no error screen). There is also no retry/backoff code anywhere in this
 * module (see otaManager.ts / main.tsx) -- the only two call sites are the
 * one-shot call on app start and the `resume` listener, so "at most one
 * check per app start/resume" is true by construction, not by a counter
 * this suite could race.
 */
describe("ota on native: manifest fetch/verify edge cases never crash, retry, or replace a working bundle", () => {
  const REAL_MANIFEST_URL_SUBSTRING = "/ota/technician-test/manifest.json"

  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(Capacitor.isNativePlatform).mockReturnValue(true)
    vi.mocked(CapacitorAppMock.getInfo).mockResolvedValue({ build: "1" } as never)
    // fetchManifest() builds its URL from `location.origin`, which this repo's
    // Node vitest environment doesn't provide (see router.test.ts's own note
    // on why DOM globals aren't available here) -- without this, every test
    // below would fail inside fetchManifest itself ("location is not
    // defined") before ever reaching the mocked fetch, which would silently
    // test the wrong thing.
    vi.stubGlobal("location", { origin: "https://gv-mart.vercel.app" })
  })

  afterEach(() => {
    vi.mocked(Capacitor.isNativePlatform).mockReturnValue(false)
    vi.unstubAllGlobals()
  })

  function expectNoBundleReplacementAndNoErrorScreen() {
    expect(CapacitorUpdater.download).not.toHaveBeenCalled()
    expect(CapacitorUpdater.next).not.toHaveBeenCalled()
    expect(setStoreUpdateRequired).not.toHaveBeenCalledWith(true)
  }

  it("a 200 response whose body is HTML, not JSON (exactly what the unpublished production channel returns live) resolves cleanly, never throws, never replaces the bundle", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) => {
        expect(String(url)).toContain(REAL_MANIFEST_URL_SUBSTRING)
        return new Response("<!doctype html><html><body>SPA fallback</body></html>", { status: 200, headers: { "content-type": "text/html" } })
      })
    )

    const result = await checkForOtaUpdate()

    expect(result.status).toBe("error") // response.ok is true at 200, so it reaches response.json(), which throws on HTML -- caught by the outer try/catch
    expectNoBundleReplacementAndNoErrorScreen()
  })

  it("a genuinely offline fetch (network request rejects, not just a bad status) resolves cleanly, never throws, never replaces the bundle", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("Failed to fetch")
      })
    )

    const result = await checkForOtaUpdate()

    expect(result.status).toBe("error")
    expectNoBundleReplacementAndNoErrorScreen()
  })

  it("a reachable server returning a non-ok status for the manifest (e.g. a real 404) is the one path labeled status: 'offline', and behaves the same way", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("Not Found", { status: 404 }))
    )

    const result = await checkForOtaUpdate()

    expect(result).toEqual({ status: "offline" })
    expectNoBundleReplacementAndNoErrorScreen()
  })

  it("a validly-shaped manifest with a wrong/forged signature is rejected by the real verifyManifestSignature, resolves cleanly, never replaces the bundle", async () => {
    const manifest = {
      channel: "technician-test",
      version: "9999-99-99-b9999",
      buildNumber: 9999,
      url: "https://gv-mart.vercel.app/ota/technician-test/bundle-9999.zip",
      checksum: "0".repeat(64),
      minNativeBuild: 1,
      frozen: false,
      publishedAt: new Date().toISOString(),
      // Well-formed base64 of 64 bytes, but not a real signature over this payload.
      signature: btoa(String.fromCharCode(...new Uint8Array(64).fill(1))),
    }
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify(manifest), { status: 200, headers: { "content-type": "application/json" } }))
    )

    const result = await checkForOtaUpdate()

    expect(result).toEqual({ status: "invalid-signature" })
    expectNoBundleReplacementAndNoErrorScreen()
    // Never even reaches the native-build compatibility check for a forged manifest.
    expect(CapacitorAppMock.getInfo).not.toHaveBeenCalled()
  })

  it("a validly-shaped manifest with no signature field at all is rejected the same way, not a crash", async () => {
    const manifestNoSig = {
      channel: "technician-test",
      version: "1",
      buildNumber: 1,
      url: "https://example.invalid/bundle.zip",
      checksum: "0".repeat(64),
      minNativeBuild: 1,
      frozen: false,
      publishedAt: new Date().toISOString(),
    }
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify(manifestNoSig), { status: 200 }))
    )

    const result = await checkForOtaUpdate()

    expect(result).toEqual({ status: "invalid-signature" })
    expectNoBundleReplacementAndNoErrorScreen()
  })
})
