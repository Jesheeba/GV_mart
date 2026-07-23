import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as reports from "@/services/reports"
import type { CreateExpenseInput, DateRange } from "@/services/reports"

export function useSalesServiceReport(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "salesService", orgId, range],
    queryFn: () => reports.getSalesServiceReport(orgId!, range),
    enabled: !!orgId,
  })
}

export function usePnlReport(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "pnl", orgId, range],
    queryFn: () => reports.getPnlReport(orgId!, range),
    enabled: !!orgId,
  })
}

export function usePerformanceReport(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "performance", orgId, range],
    queryFn: () => reports.getPerformanceReport(orgId!, range),
    enabled: !!orgId,
    // "Live KRA/KPI scoreboard" gap fix — this was fetch-on-load only, with no
    // auto-refresh, so numbers went stale until someone changed the date range
    // or reloaded the page. 60s matches this app's other "live" dashboard polls.
    refetchInterval: 60_000,
  })
}

export function useOpsResolutionKpi(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "opsResolutionKpi", orgId, range],
    queryFn: () => reports.getOpsResolutionKpi(orgId!, range),
    enabled: !!orgId,
    refetchInterval: 60_000,
  })
}

export function useFeedbackReport(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "feedback", orgId, range],
    queryFn: () => reports.getFeedbackReport(orgId!, range),
    enabled: !!orgId,
  })
}

/** ADM-28 gap fix — logs an expense in any expense_category; invalidates the
 * (prefix-matched) P&L query key so the new expense shows up immediately
 * regardless of which org/range the report is currently viewing. */
export function useCreateExpense() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateExpenseInput) => reports.createExpense(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["reports", "pnl"] }),
  })
}
