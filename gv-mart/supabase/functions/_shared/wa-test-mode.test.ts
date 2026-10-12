import { describe, expect, it, vi } from "vitest"
import { evaluateTestMode, logBlockedSend, toBareMobile } from "./wa-test-mode"

// minimal fake of the one query shape evaluateTestMode uses: from().select().eq().abortSignal().maybeSingle()
function fakeAdmin(result: { data: unknown; error: { message: string } | null }, inserts: unknown[] = []) {
  const chain = {
    select: () => chain,
    eq: () => chain,
    abortSignal: () => chain,
    maybeSingle: () => Promise.resolve(result),
  }
  return {
    from: (table: string) => (table === "audit_log" ? { insert: (row: unknown) => { inserts.push(row); return Promise.resolve({ error: null }) } } : chain),
  } as never
}

describe("toBareMobile", () => {
  it("keeps the last ten digits", () => {
    expect(toBareMobile("+91 90000-00001")).toBe("9000000001")
    expect(toBareMobile("9000000001")).toBe("9000000001")
    expect(toBareMobile(null)).toBe("")
  })
})

describe("evaluateTestMode", () => {
  it("allows everything when test mode is off (the default)", async () => {
    const admin = fakeAdmin({ data: { wa_test_mode_enabled: false, wa_test_allowed_numbers: [] }, error: null })
    expect(await evaluateTestMode(admin, "o", "9111111111")).toEqual({ blocked: false })
  })
  it("allows a missing settings row (nothing configured)", async () => {
    expect(await evaluateTestMode(fakeAdmin({ data: null, error: null }), "o", "9111111111")).toEqual({ blocked: false })
  })
  it("blocks a number that is not on the list when test mode is on", async () => {
    const admin = fakeAdmin({ data: { wa_test_mode_enabled: true, wa_test_allowed_numbers: ["9000000001"] }, error: null })
    expect(await evaluateTestMode(admin, "o", "9111111111")).toEqual({ blocked: true, reason: "test_mode_not_allow_listed" })
  })
  it("allows a listed number, however it is formatted", async () => {
    const admin = fakeAdmin({ data: { wa_test_mode_enabled: true, wa_test_allowed_numbers: ["9000000001"] }, error: null })
    expect(await evaluateTestMode(admin, "o", "919000000001")).toEqual({ blocked: false })
  })
  it("blocks everything when test mode is on and the list is empty", async () => {
    const admin = fakeAdmin({ data: { wa_test_mode_enabled: true, wa_test_allowed_numbers: [] }, error: null })
    expect((await evaluateTestMode(admin, "o", "9000000001")).blocked).toBe(true)
  })
  it("fails closed when settings cannot be read", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {})
    const admin = fakeAdmin({ data: null, error: { message: "boom" } })
    expect(await evaluateTestMode(admin, "o", "9000000001")).toEqual({ blocked: true, reason: "settings_unreadable" })
  })
})

describe("logBlockedSend", () => {
  it("writes an audit row holding only the last four digits", async () => {
    const inserts: Record<string, unknown>[] = []
    await logBlockedSend(fakeAdmin({ data: null, error: null }, inserts), {
      orgId: "o", to: "9000000001", template: "wa.menu", refType: "service_ticket", refId: "r", reason: "test_mode_not_allow_listed",
    })
    expect(inserts).toHaveLength(1)
    expect(inserts[0].action).toBe("WA_SEND_BLOCKED")
    expect(JSON.stringify(inserts[0])).not.toContain("9000000001")
    expect((inserts[0].after as { to_last4: string }).to_last4).toBe("0001")
  })
})
