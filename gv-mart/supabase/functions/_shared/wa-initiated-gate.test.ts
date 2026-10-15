import { describe, expect, it } from "vitest"
import { evaluateInitiatedGate } from "./wa-test-mode"

// the one query shape the gate uses: from().select().eq().abortSignal().maybeSingle()
function fakeAdmin(result: { data: unknown; error: { message: string } | null }) {
  const chain = { select: () => chain, eq: () => chain, abortSignal: () => chain, maybeSingle: () => Promise.resolve(result) }
  return { from: () => chain } as never
}
const row = (o: Record<string, unknown>) => ({ data: { wa_initiated_allowlist_only: true, wa_test_allowed_numbers: ["9000000001"], ...o }, error: null })

describe("evaluateInitiatedGate (design B)", () => {
  it("allows a listed recipient in any formatting", async () => {
    expect(await evaluateInitiatedGate(fakeAdmin(row({})), "o", "9000000001")).toEqual({ blocked: false })
    expect(await evaluateInitiatedGate(fakeAdmin(row({})), "o", "+91 90000 00001")).toEqual({ blocked: false })
  })
  it("blocks an unlisted recipient", async () => {
    expect(await evaluateInitiatedGate(fakeAdmin(row({})), "o", "9111111111")).toEqual({ blocked: true, reason: "initiated_not_allow_listed" })
  })
  it("fails closed on an empty or null list", async () => {
    for (const list of [[], null, undefined, "9000000001"]) {
      expect(await evaluateInitiatedGate(fakeAdmin(row({ wa_test_allowed_numbers: list })), "o", "9000000001")).toMatchObject({ blocked: true })
    }
  })
  it("fails closed on a read error, a missing row or a missing column", async () => {
    expect(await evaluateInitiatedGate(fakeAdmin({ data: null, error: { message: "boom" } }), "o", "9000000001")).toEqual({ blocked: true, reason: "initiated_settings_unreadable" })
    expect(await evaluateInitiatedGate(fakeAdmin({ data: null, error: null }), "o", "9000000001")).toEqual({ blocked: true, reason: "initiated_settings_unreadable" })
    expect(await evaluateInitiatedGate(fakeAdmin({ data: null, error: { message: 'column "wa_initiated_allowlist_only" does not exist' } }), "o", "9000000001")).toMatchObject({ blocked: true })
  })
  it("a flag that is not exactly false keeps the gate closed", async () => {
    for (const v of [true, null, undefined, "false", 0]) {
      expect(await evaluateInitiatedGate(fakeAdmin(row({ wa_initiated_allowlist_only: v })), "o", "9111111111")).toMatchObject({ blocked: true })
    }
  })
  it("go-live switch: wa_initiated_allowlist_only = false lets every recipient through", async () => {
    expect(await evaluateInitiatedGate(fakeAdmin(row({ wa_initiated_allowlist_only: false, wa_test_allowed_numbers: [] })), "o", "9111111111")).toEqual({ blocked: false })
  })
  it("never lets a malformed recipient through while the gate is closed", async () => {
    for (const to of ["", "12345", "not a number"]) {
      expect(await evaluateInitiatedGate(fakeAdmin(row({ wa_test_allowed_numbers: ["", "123"] })), "o", to)).toMatchObject({ blocked: true })
    }
  })
})
