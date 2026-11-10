import { describe, expect, it, vi } from "vitest"

/**
 * Billing-blocker inventory cleanup (2026-11-02) — searchProducts backs the
 * InstallationSelectStep picker a technician uses to log what they just
 * installed. It must only ever offer active products: once the old demo
 * catalog is archived (is_active=false), a technician should never be able
 * to pick one of those rows for a new installation.
 */
const calls: { method: string; args: unknown[] }[] = []

function fromBuilder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: [{ id: "p1", name: "Aakash's active RO" }], error: null })
      }
      return (...args: unknown[]) => {
        calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: { from: () => fromBuilder() },
}))

import { searchProducts } from "@/services/technician"

describe("searchProducts", () => {
  it("filters to is_active=true (never offers an archived product to a technician)", async () => {
    calls.length = 0
    await searchProducts("org-1", "")
    expect(calls).toEqual(
      expect.arrayContaining([
        { method: "eq", args: ["org_id", "org-1"] },
        { method: "eq", args: ["is_active", true] },
      ])
    )
  })

  it("still applies the search term via ilike alongside the active filter", async () => {
    calls.length = 0
    await searchProducts("org-1", "RO")
    expect(calls).toEqual(expect.arrayContaining([{ method: "ilike", args: ["name", "%RO%"] }]))
  })

  it("returns the rows from the query as-is", async () => {
    const result = await searchProducts("org-1", "")
    expect(result).toEqual([{ id: "p1", name: "Aakash's active RO" }])
  })
})
