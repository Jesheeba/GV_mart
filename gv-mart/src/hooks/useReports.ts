import { useQuery } from "@tanstack/react-query"
import * as reports from "@/services/reports"
import type { DateRange } from "@/services/reports"

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
  })
}

export function useOpsResolutionKpi(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "opsResolutionKpi", orgId, range],
    queryFn: () => reports.getOpsResolutionKpi(orgId!, range),
    enabled: !!orgId,
  })
}

export function useFeedbackReport(orgId: string | undefined, range: DateRange) {
  return useQuery({
    queryKey: ["reports", "feedback", orgId, range],
    queryFn: () => reports.getFeedbackReport(orgId!, range),
    enabled: !!orgId,
  })
}
