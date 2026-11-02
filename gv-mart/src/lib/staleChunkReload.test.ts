import { describe, expect, it } from "vitest"
import { shouldReloadOnPreloadError, type KeyValueStore } from "./staleChunkReload"

function fakeStorage(): KeyValueStore {
  const map = new Map<string, string>()
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => map.set(key, value),
  }
}

describe("shouldReloadOnPreloadError (stale-chunk fix)", () => {
  it("is true the first time -- a fresh session should reload once on a preload error", () => {
    expect(shouldReloadOnPreloadError(fakeStorage())).toBe(true)
  })

  it("is false the second time in the same session -- never loops forever", () => {
    const storage = fakeStorage()
    expect(shouldReloadOnPreloadError(storage)).toBe(true)
    expect(shouldReloadOnPreloadError(storage)).toBe(false)
    expect(shouldReloadOnPreloadError(storage)).toBe(false)
  })

  it("marks the flag in storage so it survives across separate calls (e.g. a second preloadError event)", () => {
    const storage = fakeStorage()
    shouldReloadOnPreloadError(storage)
    expect(storage.getItem("gv-mart-stale-chunk-reloaded")).toBe("1")
  })

  it("two independent storages (two tabs/sessions) each get their own one-time reload", () => {
    expect(shouldReloadOnPreloadError(fakeStorage())).toBe(true)
    expect(shouldReloadOnPreloadError(fakeStorage())).toBe(true)
  })
})
