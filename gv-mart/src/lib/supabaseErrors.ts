/**
 * Deploy-order safety: the technician/customer app can reach production
 * slightly before (or after) a migration that adds a given table, column or
 * RPC is applied. Postgres/PostgREST surfaces each of those as a stable
 * error code — this lets a query or mutation recover from exactly that case
 * (a calm "not available yet" message) instead of surfacing a raw Postgres
 * error, or silently treating the failure as an empty/zero result.
 */
export function isUndefinedTableError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "42P01"
}

export function isUndefinedColumnError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "42703"
}

export function isUndefinedFunctionError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "42883"
}

/** True when `error` means "this table/column/RPC doesn't exist in this
 *  environment yet" (its migration hasn't landed) — the one case that should
 *  show a calm "not available yet" message instead of a raw Postgres error
 *  or a plain generic failure message. */
export function isNotYetAvailableError(error: unknown): boolean {
  return isUndefinedTableError(error) || isUndefinedColumnError(error) || isUndefinedFunctionError(error)
}
