/**
 * Classifies a customer_auto_onboard() RPC failure for CustomerAutoOnboardGate.
 * The actual match-rule decisions (link / create / flag-and-create) all happen
 * server-side in 20261130100001_customer_auto_onboard_rpc.sql and are proven
 * there (supabase/tests/customer_auto_onboard.test.sql, run via the project's
 * rehearsal pipeline) — this is the one piece of that outcome the client
 * itself has to interpret: which message to show when the RPC throws.
 */
export function classifyOnboardError(error: unknown): "staff_account" | "error" {
  const message = error instanceof Error ? error.message : String(error ?? "")
  return message.includes("staff_account") ? "staff_account" : "error"
}
