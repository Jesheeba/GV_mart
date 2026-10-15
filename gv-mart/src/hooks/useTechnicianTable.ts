import { useQuery } from "@tanstack/react-query"
import * as svc from "@/services/technicianTable"

export function useTechnicianTable(from: string, to: string, enabled = true) {
  return useQuery({
    queryKey: ["technicianTable", from, to],
    queryFn: () => svc.getTechnicianTable(from, to),
    enabled: enabled && !!from && !!to && from <= to,
  })
}
