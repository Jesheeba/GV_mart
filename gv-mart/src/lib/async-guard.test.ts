import { describe, expect, it, vi } from "vitest"
import { guardReentry } from "./async-guard"

function deferred<T>() {
  let resolve!: (v: T) => void
  let reject!: (e: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe("guardReentry", () => {
  it("invokes fn on the first call", async () => {
    const ref = { current: false }
    const fn = vi.fn().mockResolvedValue(undefined)
    await guardReentry(ref, fn)
    expect(fn).toHaveBeenCalledTimes(1)
  })

  it("is a no-op for a second call fired while the first is still in flight -- the exact double-submit bug", async () => {
    const ref = { current: false }
    const { promise, resolve } = deferred<void>()
    const fn = vi.fn().mockReturnValue(promise)

    const first = guardReentry(ref, fn)
    const second = guardReentry(ref, fn) // fired before `first` has settled, like two fast clicks
    expect(fn).toHaveBeenCalledTimes(1) // the second call never reached fn at all

    resolve()
    await Promise.all([first, second])
    expect(fn).toHaveBeenCalledTimes(1)
  })

  it("resets the ref after success, so a later call (a real new attempt) invokes fn again", async () => {
    const ref = { current: false }
    const fn = vi.fn().mockResolvedValue(undefined)
    await guardReentry(ref, fn)
    expect(ref.current).toBe(false)
    await guardReentry(ref, fn)
    expect(fn).toHaveBeenCalledTimes(2)
  })

  it("resets the ref after a rejection too, and propagates the rejection to the caller", async () => {
    const ref = { current: false }
    const fn = vi.fn().mockRejectedValue(new Error("already exists"))
    await expect(guardReentry(ref, fn)).rejects.toThrow("already exists")
    expect(ref.current).toBe(false)
  })

  it("still blocks a concurrent second call even when the first call is destined to reject", async () => {
    const ref = { current: false }
    const { promise, reject } = deferred<void>()
    const fn = vi.fn().mockReturnValue(promise)

    const first = guardReentry(ref, fn)
    const second = guardReentry(ref, fn)
    expect(fn).toHaveBeenCalledTimes(1)

    reject(new Error("already exists"))
    await expect(first).rejects.toThrow("already exists")
    await second // resolves silently -- it was a no-op, never saw the rejection
    expect(ref.current).toBe(false)
  })
})
