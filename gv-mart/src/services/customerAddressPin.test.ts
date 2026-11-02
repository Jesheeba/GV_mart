import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * "Pin my address" (20261201100000). setMyAddressPin/clearMyAddressPin rely entirely on the
 * existing addresses_write_own RLS policy (customer_id = current_customer_id()) for ownership —
 * no RPC, no customer id passed in at all. This pins the exact `.update()` payload and the `.eq`
 * filter actually sent to Postgres, since those are the only things that could regress and quietly
 * let an update through unscoped or with stale fields.
 */
const state: { calls: { method: string; args: unknown[] }[] } = { calls: [] }

function builder(): unknown {
  const handler: ProxyHandler<object> = {
    get(_t, prop: string) {
      if (prop === "then") {
        return (resolve: (v: unknown) => void) => resolve({ data: null, error: null })
      }
      return (...args: unknown[]) => {
        state.calls.push({ method: prop, args })
        return proxy
      }
    },
  }
  const proxy: unknown = new Proxy({}, handler)
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: { from: () => builder() },
}))

import { clearMyAddressPin, setMyAddressPin } from "@/services/customerApp"

const updatePayload = () => state.calls.find((c) => c.method === "update")?.args[0] as Record<string, unknown>
const eqArgs = () => state.calls.find((c) => c.method === "eq")?.args as unknown[]

beforeEach(() => {
  state.calls = []
})

describe("setMyAddressPin", () => {
  it("writes lat/lng, pinned_at and the given accuracy, scoped to the given address id", async () => {
    await setMyAddressPin("addr-1", 13.08, 80.27, 12.5)
    const payload = updatePayload()
    expect(payload.lat).toBe(13.08)
    expect(payload.lng).toBe(80.27)
    expect(payload.location_accuracy_m).toBe(12.5)
    expect(typeof payload.pinned_at).toBe("string")
    expect(eqArgs()).toEqual(["id", "addr-1"])
  })

  it("writes a null accuracy when none is given (search/drag, not geolocation)", async () => {
    await setMyAddressPin("addr-1", 13.08, 80.27)
    expect(updatePayload().location_accuracy_m).toBeNull()
  })

  it("address-from-location: merges an optional text-fields patch into the same update, without disturbing lat/lng/pinned_at", async () => {
    await setMyAddressPin("addr-1", 13.08, 80.27, 9, { area: "Adyar", pincode: "600020" })
    const payload = updatePayload()
    expect(payload.lat).toBe(13.08)
    expect(payload.lng).toBe(80.27)
    expect(payload.area).toBe("Adyar")
    expect(payload.pincode).toBe("600020")
    expect("door_no" in payload).toBe(false)
    expect("street_cross" in payload).toBe(false)
    expect("district" in payload).toBe(false)
    expect("state" in payload).toBe(false)
  })

  it("address-from-location: omits a fields patch entirely when none is given -- no text columns are ever touched", async () => {
    await setMyAddressPin("addr-1", 13.08, 80.27)
    const payload = updatePayload()
    expect(Object.keys(payload).sort()).toEqual(["lat", "lng", "location_accuracy_m", "pinned_at"].sort())
  })

  it("address-from-location (defense-in-depth, independent security review): an extra key on the fields object (e.g. a caller bypassing the TypeScript type at runtime) is never forwarded to the update payload", async () => {
    const tampered = { area: "Adyar", customer_id: "someone-elses-customer-id", org_id: "another-org-id" } as never
    await setMyAddressPin("addr-1", 13.08, 80.27, undefined, tampered)
    const payload = updatePayload()
    expect(payload.area).toBe("Adyar")
    expect("customer_id" in payload).toBe(false)
    expect("org_id" in payload).toBe(false)
  })
})

describe("clearMyAddressPin", () => {
  it("nulls out lat, lng, pinned_at and accuracy together, scoped to the given address id", async () => {
    await clearMyAddressPin("addr-1")
    const payload = updatePayload()
    expect(payload).toEqual({ lat: null, lng: null, pinned_at: null, location_accuracy_m: null })
    expect(eqArgs()).toEqual(["id", "addr-1"])
  })
})
