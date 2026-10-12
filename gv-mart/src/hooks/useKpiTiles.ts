import { keepPreviousData, useQuery } from "@tanstack/react-query"
import * as reports from "@/services/reports"
import type { DateRange } from "@/services/reports"

/**
 * KPI tiles (report_kpi_tiles). The organisation is the caller's profile on the server, so the key carries only the window.
 * `retry: 1` on purpose: if the function is missing (older database) the strip shows its inline error quickly instead of
 * retrying three times; the rest of the dashboard is unaffected.
 */
export function useKpiTiles(range: DateRange, opts: { enabled?: boolean } = {}) {
  return useQuery({
    queryKey: ["kpi_tiles", range.from, range.to],
    queryFn: () => reports.getKpiTiles(range),
    enabled: opts.enabled ?? true,
    retry: 1,
    staleTime: 60_000,
    placeholderData: keepPreviousData,
  })
}
