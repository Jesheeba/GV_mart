import { describe, expect, it, vi } from "vitest"
import { subscribeGeoRecheck } from "./useGeoPermissionRecheck"

/** Plain EventTarget-based fakes -- this repo's vitest environment has no
 * DOM (see router.test.ts), but Node's global EventTarget already gives a
 * real addEventListener/removeEventListener/dispatchEvent implementation,
 * so no jsdom is needed to exercise the real subscribe/unsubscribe logic. */
function fakeDocument(initialVisibility: DocumentVisibilityState = "visible") {
  const target = new EventTarget() as unknown as Document
  Object.defineProperty(target, "visibilityState", { value: initialVisibility, writable: true })
  return target
}

function fakeWindow() {
  return new EventTarget() as unknown as Window
}

function fakePermissionStatus() {
  return new EventTarget() as unknown as PermissionStatus
}

describe("subscribeGeoRecheck", () => {
  it("calls recheck when visibilitychange fires while the document is visible", () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const recheck = vi.fn()
    subscribeGeoRecheck({ document: doc, window: win, navigator: {} as Navigator }, recheck)

    doc.dispatchEvent(new Event("visibilitychange"))
    expect(recheck).toHaveBeenCalledTimes(1)
  })

  it("does NOT call recheck when visibilitychange fires while the document is hidden (tab backgrounded, not returned to)", () => {
    const doc = fakeDocument("hidden")
    const win = fakeWindow()
    const recheck = vi.fn()
    subscribeGeoRecheck({ document: doc, window: win, navigator: {} as Navigator }, recheck)

    doc.dispatchEvent(new Event("visibilitychange"))
    expect(recheck).not.toHaveBeenCalled()
  })

  it("calls recheck on window focus -- the other half of the 'grant permission, come back to the tab' real-world flow", () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const recheck = vi.fn()
    subscribeGeoRecheck({ document: doc, window: win, navigator: {} as Navigator }, recheck)

    win.dispatchEvent(new Event("focus"))
    expect(recheck).toHaveBeenCalledTimes(1)
  })

  it("calls recheck when the Permissions API reports the geolocation permission changed", async () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const status = fakePermissionStatus()
    const query = vi.fn().mockResolvedValue(status)
    const recheck = vi.fn()

    subscribeGeoRecheck({ document: doc, window: win, navigator: { permissions: { query } } as unknown as Navigator }, recheck)
    await Promise.resolve() // flush the query() promise
    await Promise.resolve()

    status.dispatchEvent(new Event("change"))
    expect(recheck).toHaveBeenCalledTimes(1)
    expect(query).toHaveBeenCalledWith({ name: "geolocation" })
  })

  it("degrades silently when navigator.permissions.query is unsupported or rejects -- visibility/focus still work", async () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const recheck = vi.fn()

    // No navigator.permissions at all.
    const unsubscribeNoPermissionsApi = subscribeGeoRecheck({ document: doc, window: win, navigator: {} as Navigator }, recheck)
    win.dispatchEvent(new Event("focus"))
    expect(recheck).toHaveBeenCalledTimes(1)
    unsubscribeNoPermissionsApi()

    // navigator.permissions.query exists but rejects (e.g. "geolocation" name unrecognised).
    recheck.mockClear()
    const query = vi.fn().mockRejectedValue(new Error("not supported"))
    const unsubscribeRejecting = subscribeGeoRecheck(
      { document: doc, window: win, navigator: { permissions: { query } } as unknown as Navigator },
      recheck
    )
    await Promise.resolve()
    await Promise.resolve()
    win.dispatchEvent(new Event("focus"))
    expect(recheck).toHaveBeenCalledTimes(1) // from focus, not a throw from the rejected query()
    unsubscribeRejecting()
  })

  it("the returned unsubscribe function removes every listener, including the late-attached permission-status one", async () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const status = fakePermissionStatus()
    const query = vi.fn().mockResolvedValue(status)
    const recheck = vi.fn()

    const unsubscribe = subscribeGeoRecheck({ document: doc, window: win, navigator: { permissions: { query } } as unknown as Navigator }, recheck)
    await Promise.resolve()
    await Promise.resolve()

    unsubscribe()

    doc.dispatchEvent(new Event("visibilitychange"))
    win.dispatchEvent(new Event("focus"))
    status.dispatchEvent(new Event("change"))
    expect(recheck).not.toHaveBeenCalled()
  })

  it("a query() that resolves AFTER unsubscribe() never attaches a change listener (no leak, no late call)", async () => {
    const doc = fakeDocument("visible")
    const win = fakeWindow()
    const status = fakePermissionStatus()
    let resolveQuery!: (s: PermissionStatus) => void
    const query = vi.fn().mockReturnValue(new Promise<PermissionStatus>((res) => (resolveQuery = res)))
    const recheck = vi.fn()

    const unsubscribe = subscribeGeoRecheck({ document: doc, window: win, navigator: { permissions: { query } } as unknown as Navigator }, recheck)
    unsubscribe() // unsubscribed before the query() promise ever resolves
    resolveQuery(status)
    await Promise.resolve()
    await Promise.resolve()

    status.dispatchEvent(new Event("change"))
    expect(recheck).not.toHaveBeenCalled()
  })
})
