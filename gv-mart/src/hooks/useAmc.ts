import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as amc from "@/services/amc"
import type { SellAmcInput } from "@/services/amc"

export function useAmcContracts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["amc_contracts", "list", orgId],
    queryFn: () => amc.listAmcContracts(orgId!),
    enabled: !!orgId,
  })
}

export function useWarranties(orgId: string | undefined) {
  return useQuery({
    queryKey: ["warranties", "list", orgId],
    queryFn: () => amc.listWarranties(orgId!),
    enabled: !!orgId,
  })
}

export function useRoProducts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["products", "ro", orgId],
    queryFn: () => amc.listRoProducts(orgId!),
    enabled: !!orgId,
  })
}

export function useSellAmcPlan() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: SellAmcInput) => amc.sellAmcPlan(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["amc_contracts"] })
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useRefreshAmcStatuses(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => amc.refreshAmcStatuses(orgId!),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["amc_contracts"] }),
  })
}
