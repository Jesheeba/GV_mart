/**
 * Shared branching for a query-backed list section (e.g. the expenses
 * history page's claims list and km-log list): tell "query succeeded with no
 * rows" apart from "query failed" instead of letting both render the same
 * "nothing here" message, which hides a real failure (missing table/RPC/
 * column, or any other error) behind what looks like a legitimate empty state.
 */
export type SectionState = "loading" | "error" | "empty" | "data"

export function resolveSectionState(args: { isLoading: boolean; isError: boolean; isEmpty: boolean }): SectionState {
  if (args.isLoading) return "loading"
  if (args.isError) return "error"
  if (args.isEmpty) return "empty"
  return "data"
}
