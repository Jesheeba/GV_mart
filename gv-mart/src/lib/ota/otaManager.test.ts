import { describe, expect, it, vi } from "vitest"

vi.mock("@capacitor/core", () => ({ Capacitor: { isNativePlatform: () => false } }))
vi.mock("@capacitor/app", () => ({ App: { getInfo: vi.fn(), addListener: vi.fn() } }))
vi.mock("@capgo/capacitor-updater", () => ({
  CapacitorUpdater: { download: vi.fn(), next: vi.fn(), notifyAppReady: vi.fn(), current: vi.fn() },
}))

const { checkForOtaUpdate, notifyOtaAppReady, getOtaVersionInfo } = await import("./otaManager")
const { CapacitorUpdater } = await import("@capgo/capacitor-updater")

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
