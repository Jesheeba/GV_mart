/**
 * Deploy-order safety (FEATURE_CUSTOMER_WATER_HOUSEHOLD_PROFILE.md §6): the web app can
 * reach production slightly before or after the migration that adds a given column is applied.
 * Postgres/PostgREST surfaces a missing column as error code 42703 (undefined_column) — this
 * lets a query recover from exactly that case instead of crashing the whole page.
 */
export function isUndefinedColumnError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: unknown }).code === "42703"
}
