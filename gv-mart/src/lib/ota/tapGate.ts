/**
 * Counts quick repeated taps so switching OTA channels from the Profile
 * screen takes a deliberate gesture, not one accidental tap — a technician
 * on "production" must never land on "technician-test" by mistake.
 *
 * Pure and DOM-free on purpose so it's unit-testable without a browser; the
 * caller owns the single piece of mutable state (the previous result) and
 * feeds back its own clock.
 */
export const TAPS_REQUIRED = 7
const MAX_GAP_MS = 1200

export type TapGateState = { count: number; lastTapAt: number }
export type TapGateResult = TapGateState & { triggered: boolean }

/** `prev` is `null` for the very first tap, or whenever the caller wants to reset the sequence. */
export function nextTapGateState(now: number, prev: TapGateState | null): TapGateResult {
  const withinWindow = prev !== null && now - prev.lastTapAt <= MAX_GAP_MS
  const count = withinWindow ? prev.count + 1 : 1
  if (count >= TAPS_REQUIRED) {
    return { count: 0, lastTapAt: now, triggered: true }
  }
  return { count, lastTapAt: now, triggered: false }
}
