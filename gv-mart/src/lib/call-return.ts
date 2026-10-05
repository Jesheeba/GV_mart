// "Tap Call, come back, log what happened" — remembers which lead the user
// just dialled so the app can open the Log Outcome sheet when they return.
// sessionStorage (per tab) is purely a convenience: every access is guarded,
// and nothing here is required for correctness.

const KEY = "gvmart.pendingCall"
/** Ignore a "return" that happens within this many ms of tapping Call (the tap itself blurs/refocuses). */
const MIN_AWAY_MS = 2000
/** A pending call older than this is stale — the user wandered off for good. */
const MAX_AGE_MS = 6 * 60 * 60 * 1000

export type PendingCall = {
  id: string
  name: string
  mobile: string | null
  status: "new" | "contacted" | "quoted" | "won" | "lost"
  startedAt: number
  /** Set once the page was hidden/blurred after the tap (i.e. the dialler/WhatsApp actually took over). */
  left: boolean
  leftAt: number | null
}

function read(): PendingCall | null {
  try {
    const raw = sessionStorage.getItem(KEY)
    return raw ? (JSON.parse(raw) as PendingCall) : null
  } catch {
    return null
  }
}

function write(call: PendingCall | null) {
  try {
    if (call) sessionStorage.setItem(KEY, JSON.stringify(call))
    else sessionStorage.removeItem(KEY)
  } catch {
    // storage unavailable — the prompt simply won't appear
  }
}

export function rememberCall(lead: { id: string; name: string; mobile: string | null; status: PendingCall["status"] }) {
  write({ ...lead, startedAt: Date.now(), left: false, leftAt: null })
}

/** The page was hidden/blurred: if a call is pending, note that the user left. */
export function markLeft() {
  const c = read()
  if (c && !c.left) write({ ...c, left: true, leftAt: Date.now() })
}

/** The page is visible/focused again: returns the pending call if the user really left and came back, else null. */
export function takeReturnedCall(now = Date.now()): PendingCall | null {
  const c = read()
  if (!c) return null
  if (now - c.startedAt > MAX_AGE_MS) {
    write(null)
    return null
  }
  if (!c.left || c.leftAt === null || now - c.leftAt < MIN_AWAY_MS) return null
  write(null)
  return c
}

export function clearPendingCall() {
  write(null)
}
