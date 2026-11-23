import { beforeEach, describe, expect, it, vi } from "vitest"

// Login Activity (build-docs/features/login-activity.md). DB-side criteria (capture, RLS, org isolation, role
// rejection, retention) are covered by supabase/tests/login_activity.test.sql; these cover the client contract.

const rpc = vi.fn()
vi.mock("@/lib/supabase", () => ({ supabase: { rpc: (...a: unknown[]) => rpc(...a) } }))

import {
  describeDevice,
  formatDuration,
  listLoginActivity,
  loginActivityParamsSchema,
  sessionDurationMinutes,
} from "@/services/loginActivity"

const base = { from: "2026-11-17", to: "2026-11-23", role: "all" as const, search: "", page: 0 }

beforeEach(() => rpc.mockReset())

describe("AC5 listLoginActivity sends the filters and pages to the RPC", () => {
  it("maps params, empty search → null, page → offset", async () => {
    rpc.mockResolvedValue({ data: [{ session_id: "a", total_count: 120 }], error: null })
    const res = await listLoginActivity({ ...base, role: "customer", page: 2 })
    expect(rpc).toHaveBeenCalledWith("list_login_activity", {
      p_from: "2026-11-17", p_to: "2026-11-23", p_role: "customer", p_search: null, p_limit: 50, p_offset: 100,
    })
    expect(res.total).toBe(120)
    expect(res.rows).toHaveLength(1)
  })

  it("trims the search text", async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    await listLoginActivity({ ...base, search: "  ravi " })
    expect(rpc.mock.calls[0][1]).toMatchObject({ p_search: "ravi" })
  })

  it("empty result → total 0", async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    expect(await listLoginActivity(base)).toEqual({ rows: [], total: 0 })
  })

  it("AC6 propagates a permission error from the RPC (non-master)", async () => {
    rpc.mockResolvedValue({ data: null, error: { code: "42501", message: "only a master can view login activity" } })
    await expect(listLoginActivity(base)).rejects.toMatchObject({ code: "42501" })
  })
})

describe("edge cases: invalid input never reaches the RPC", () => {
  it.each([
    ["from after to", { from: "2026-11-24", to: "2026-11-23" }],
    ["range over 366 days", { from: "2025-01-01", to: "2026-11-23" }],
    ["bad date format", { from: "23/11/2026" }],
    ["unknown role", { role: "hacker" }],
    ["negative page", { page: -1 }],
    ["search over 100 chars", { search: "x".repeat(101) }],
  ])("%s is rejected", async (_label, patch) => {
    const params = { ...base, ...patch } as never
    expect(loginActivityParamsSchema.safeParse(params).success).toBe(false)
    await expect(listLoginActivity(params)).rejects.toThrow()
    expect(rpc).not.toHaveBeenCalled()
  })

  it("a single-day range is valid", () => {
    expect(loginActivityParamsSchema.safeParse({ ...base, from: "2026-11-23", to: "2026-11-23" }).success).toBe(true)
  })
})

describe("AC4 device column", () => {
  it.each([
    ["Mozilla/5.0 (Linux; Android 14; SM-A146B Build/UP1A; wv) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36", "Android app"],
    ["Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36", "Chrome · Android"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36 Edg/130", "Edge · Windows"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130 Safari/537.36", "Chrome · Windows"],
    ["Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile Safari/604.1", "Safari · iPhone"],
    ["Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0; rv:130.0) Gecko/20100101 Firefox/130.0", "Firefox · Mac"],
    ["curl/8.4.0", "Other"],
  ])("%s → %s", (ua, label) => expect(describeDevice(ua)).toBe(label))

  it("missing user agent → null (shown as —)", () => {
    expect(describeDevice(null)).toBeNull()
    expect(describeDevice("")).toBeNull()
  })
})

describe("AC4 duration column", () => {
  const start = "2026-11-23T04:00:00.000Z"
  it("uses logout when signed out", () => {
    expect(sessionDurationMinutes({ started_at: start, ended_at: "2026-11-23T06:05:00.000Z", last_seen_at: "2026-11-23T09:00:00.000Z" })).toBe(125)
  })
  it("falls back to last active while still signed in", () => {
    expect(sessionDurationMinutes({ started_at: start, ended_at: null, last_seen_at: "2026-11-23T04:30:00.000Z" })).toBe(30)
  })
  it("unknown end or clock skew → null", () => {
    expect(sessionDurationMinutes({ started_at: start, ended_at: null, last_seen_at: null })).toBeNull()
    expect(sessionDurationMinutes({ started_at: start, ended_at: "2026-11-23T03:00:00.000Z", last_seen_at: null })).toBeNull()
  })
  it.each([
    [null, "—"], [0, "<1m"], [12, "12m"], [125, "2h 05m"], [60 * 24 * 3 + 240, "3d 4h"],
  ])("formatDuration(%s) → %s", (m, out) => expect(formatDuration(m)).toBe(out))
})
