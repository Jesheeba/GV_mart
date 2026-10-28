import { describe, expect, it, vi } from "vitest"

/**
 * Unit coverage for the "Ops resolution matches" parity test's skip decision (reports.parity.test.ts), which is
 * otherwise only exercised live against a throwaway org. The settings fetch is mocked here so all four cases —
 * including the one real DDL can't produce (a NOT NULL column can never actually be null once the migration is
 * live) — are provable without a database.
 */
let mockResult: { data: { ops_resolution_sla_hours: number | null } | null; error: null }

vi.mock("@/lib/supabase", () => ({
  supabase: {
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => mockResult,
        }),
      }),
    }),
  },
}))

import { getOpsResolutionParitySlaHours, opsResolutionParitySkipReason } from "@/services/reports"

describe("ops-resolution parity skip decision (mocked settings fetch)", () => {
  it("ops_resolution_sla_hours is null -> defaults to 24 -> the comparison RUNS", async () => {
    mockResult = { data: { ops_resolution_sla_hours: null }, error: null }
    const slaHours = await getOpsResolutionParitySlaHours("org-1")
    expect(slaHours).toBe(24)
    expect(opsResolutionParitySkipReason(slaHours)).toBeNull()
  })

  it("ops_resolution_sla_hours is 24 -> the comparison RUNS", async () => {
    mockResult = { data: { ops_resolution_sla_hours: 24 }, error: null }
    const slaHours = await getOpsResolutionParitySlaHours("org-1")
    expect(slaHours).toBe(24)
    expect(opsResolutionParitySkipReason(slaHours)).toBeNull()
  })

  it("ops_resolution_sla_hours is 48 -> SKIPS, with 48 in the message", async () => {
    mockResult = { data: { ops_resolution_sla_hours: 48 }, error: null }
    const slaHours = await getOpsResolutionParitySlaHours("org-1")
    expect(slaHours).toBe(48)
    const reason = opsResolutionParitySkipReason(slaHours)
    expect(reason).not.toBeNull()
    expect(reason).toContain("48")
  })

  it("no settings row at all (maybeSingle returns null) -> defaults to 24 -> the comparison RUNS", async () => {
    mockResult = { data: null, error: null }
    const slaHours = await getOpsResolutionParitySlaHours("org-1")
    expect(slaHours).toBe(24)
    expect(opsResolutionParitySkipReason(slaHours)).toBeNull()
  })
})
