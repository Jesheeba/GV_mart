// Which recipients use the dispatcher v2 path (pure; no Deno, no client). Settings columns, migration 20261016330000:
//   wa_dispatch_v2_enabled  boolean  master switch (default false)
//   wa_dispatch_v2_scope    'numbers' | 'org'  (default 'numbers')
//   wa_dispatch_v2_numbers  text[]   bare 10-digit numbers (default empty)
//
// v2 applies to a recipient only when the switch is ON and either
//   - scope = 'org' (explicit, deliberate: everyone), or
//   - scope = 'numbers' and the recipient's LAST TEN DIGITS are in the list.
// An EMPTY list therefore means nobody uses v2: switching the flag on can never accidentally turn it on for the whole
// organisation. Everyone v2 does not apply to stays on the legacy path exactly as before. Any read problem, any missing
// column, any unexpected value fails closed (legacy).

export type DispatchV2Scope = { enabled: boolean; scope: "numbers" | "org"; numbers: string[] }

export const DISPATCH_V2_OFF: DispatchV2Scope = { enabled: false, scope: "numbers", numbers: [] }

export function last10Digits(raw: string | null | undefined): string {
  return (raw ?? "").replace(/\D/g, "").slice(-10)
}

/** Builds the scope from a settings row; anything unexpected gives "nobody". */
export function parseDispatchV2Scope(row: unknown): DispatchV2Scope {
  if (!row || typeof row !== "object") return DISPATCH_V2_OFF
  const r = row as { wa_dispatch_v2_enabled?: unknown; wa_dispatch_v2_scope?: unknown; wa_dispatch_v2_numbers?: unknown }
  if (r.wa_dispatch_v2_enabled !== true) return DISPATCH_V2_OFF
  const numbers = Array.isArray(r.wa_dispatch_v2_numbers)
    ? (r.wa_dispatch_v2_numbers as unknown[]).map((n) => (typeof n === "string" ? last10Digits(n) : "")).filter((n) => /^[0-9]{10}$/.test(n))
    : []
  return { enabled: true, scope: r.wa_dispatch_v2_scope === "org" ? "org" : "numbers", numbers }
}

/** True when this recipient is sent through v2. */
export function v2AppliesTo(scope: DispatchV2Scope, to: string | null | undefined): boolean {
  if (!scope.enabled) return false
  if (scope.scope === "org") return true
  const n = last10Digits(to)
  return /^[0-9]{10}$/.test(n) && scope.numbers.includes(n)
}

/** True when v2 is on for at least one recipient (the dispatcher loops need to run their v2 half). */
export function v2Active(scope: DispatchV2Scope): boolean {
  return scope.enabled && (scope.scope === "org" || scope.numbers.length > 0)
}
