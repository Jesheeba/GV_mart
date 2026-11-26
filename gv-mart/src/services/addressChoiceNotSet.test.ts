import { beforeEach, describe, expect, it, vi } from "vitest"

/**
 * Address type / ownership "Not set" (owner, 2026-11-26; 20261229100000_address_choice_not_set.sql): every write
 * path sends an explicit null, so the DB stores "Not set" instead of a default, and an edit back to "Not set"
 * clears an earlier answer (a missing key would leave the old value in place).
 */
const calls: { kind: string; method: string; args: unknown[] }[] = []

function builder(kind: string): unknown {
  const proxy: unknown = new Proxy(
    {},
    {
      get(_t, prop: string) {
        if (prop === "then") return (resolve: (v: unknown) => void) => resolve({ data: { id: "addr-1" }, error: null })
        return (...args: unknown[]) => {
          calls.push({ kind, method: prop, args })
          return proxy
        }
      },
    }
  )
  return proxy
}

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: (table: string) => builder(`from:${table}`),
    rpc: (name: string, args: unknown) => {
      calls.push({ kind: "rpc", method: name, args: [args] })
      return Promise.resolve({ data: "cust-1", error: null })
    },
  },
}))

import { createCustomerWithDetails, upsertPrimaryAddress } from "@/services/customers"
import { addMyAddress, updateMyAddress } from "@/services/customerApp"

const written = (method: "insert" | "update") =>
  calls.find((c) => c.kind === "from:addresses" && c.method === method)?.args[0] as Record<string, unknown>

beforeEach(() => {
  calls.length = 0
})

describe("address type / ownership: Not set is written as null", () => {
  it("admin create: the RPC gets address_type/ownership null, not missing and not 'residential'/'own'", async () => {
    await createCustomerWithDetails({ orgId: "org", members: [{ name: "A", mobile: "9876543210", isPrimary: true }], address: { area: "Anna Nagar" } })
    const args = calls.find((c) => c.kind === "rpc" && c.method === "create_customer_with_details")!.args[0] as { p_address: Record<string, unknown> }
    expect(args.p_address).toHaveProperty("address_type", null)
    expect(args.p_address).toHaveProperty("ownership", null)
  })

  it("admin create: a chosen value passes through unchanged", async () => {
    await createCustomerWithDetails({ orgId: "org", members: [{ name: "A", mobile: "9876543210", isPrimary: true }], address: { addressType: "commercial", ownership: "rental" } })
    const args = calls.find((c) => c.kind === "rpc")!.args[0] as { p_address: Record<string, unknown> }
    expect(args.p_address).toMatchObject({ address_type: "commercial", ownership: "rental" })
  })

  it("admin edit: changing back to Not set clears the saved answer (explicit null in the update)", async () => {
    await upsertPrimaryAddress("org", "cust", "addr-1", { area: "Anna Nagar" })
    expect(written("update")).toHaveProperty("address_type", null)
    expect(written("update")).toHaveProperty("ownership", null)
  })

  it("admin edit: a new primary address with Not set inserts null", async () => {
    await upsertPrimaryAddress("org", "cust", null, { area: "Anna Nagar", ownership: "own" })
    expect(written("insert")).toMatchObject({ address_type: null, ownership: "own" })
  })

  it("customer app add + edit: Not set is null on insert and on update", async () => {
    const input = { fullAddress: "12, 2nd Street", area: "Anna Nagar", pincode: "600040" }
    await addMyAddress("org", "cust", input, false)
    expect(written("insert")).toMatchObject({ address_type: null, ownership: null })
    calls.length = 0
    await updateMyAddress("addr-1", { ...input, addressType: "residential" })
    expect(written("update")).toMatchObject({ address_type: "residential", ownership: null })
  })
})
