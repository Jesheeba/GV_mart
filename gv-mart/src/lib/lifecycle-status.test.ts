import { describe, expect, it } from "vitest"
import { lifecycleStatusTone, LIFECYCLE_STATUS_TONE } from "./lifecycle-status"

describe("lifecycleStatusTone", () => {
  it("maps every known status to its tone", () => {
    expect(lifecycleStatusTone("due_soon")).toBe("info")
    expect(lifecycleStatusTone("due")).toBe("warning")
    expect(lifecycleStatusTone("overdue")).toBe("danger")
    expect(lifecycleStatusTone("lifetime_expiring_90d")).toBe("warning")
  })

  it("falls back to neutral for an unrecognised status instead of throwing", () => {
    expect(lifecycleStatusTone("unknown")).toBe("neutral")
    expect(lifecycleStatusTone("")).toBe("neutral")
  })

  it("covers every key declared on the tone map", () => {
    for (const status of Object.keys(LIFECYCLE_STATUS_TONE)) {
      expect(lifecycleStatusTone(status)).toBe(LIFECYCLE_STATUS_TONE[status as keyof typeof LIFECYCLE_STATUS_TONE])
    }
  })
})
