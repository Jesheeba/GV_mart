import { describe, expect, it } from "vitest"
import { nextTapGateState, TAPS_REQUIRED } from "./tapGate"

describe("nextTapGateState", () => {
  it("does not trigger on a single tap", () => {
    const result = nextTapGateState(1000, null)
    expect(result.triggered).toBe(false)
    expect(result.count).toBe(1)
  })

  it("does not trigger on one tap short of the requirement", () => {
    let state = nextTapGateState(0, null)
    for (let i = 1; i < TAPS_REQUIRED - 1; i++) {
      state = nextTapGateState(i * 100, state)
    }
    expect(state.count).toBe(TAPS_REQUIRED - 1)
    expect(state.triggered).toBe(false)
  })

  it("triggers on exactly the required number of quick taps", () => {
    let state = nextTapGateState(0, null)
    let result = state
    for (let i = 1; i < TAPS_REQUIRED; i++) {
      result = nextTapGateState(i * 100, result)
    }
    expect(result.triggered).toBe(true)
    expect(result.count).toBe(0) // resets after triggering
  })

  it("a single accidental tap (the realistic 'must never move by accident' case) never triggers", () => {
    const result = nextTapGateState(Date.now(), null)
    expect(result.triggered).toBe(false)
  })

  it("resets the count if a tap arrives too slowly (not a quick sequence)", () => {
    let state = nextTapGateState(0, null)
    for (let i = 1; i < TAPS_REQUIRED - 1; i++) {
      state = nextTapGateState(i * 100, state)
    }
    expect(state.count).toBe(TAPS_REQUIRED - 1)
    // A slow 8th tap, 5 seconds later, should restart the count at 1 — not complete the sequence.
    const slowTap = nextTapGateState(state.lastTapAt + 5000, state)
    expect(slowTap.count).toBe(1)
    expect(slowTap.triggered).toBe(false)
  })

  it("a slow drip of taps (one every 5s, forever) never triggers even past the required count", () => {
    let state: ReturnType<typeof nextTapGateState> | null = null
    let now = 0
    for (let i = 0; i < TAPS_REQUIRED * 3; i++) {
      now += 5000
      state = nextTapGateState(now, state)
      expect(state.triggered).toBe(false)
    }
  })
})
