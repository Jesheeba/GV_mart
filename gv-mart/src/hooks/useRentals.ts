import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as rentals from "@/services/rentals"
import type { CreateRentalInput } from "@/services/rentals"

export function useRentalContracts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["rental_contracts", "list", orgId],
    queryFn: () => rentals.listRentalContracts(orgId!),
    enabled: !!orgId,
  })
}

export function useCustomerRentalContracts(customerId: string | undefined) {
  return useQuery({
    queryKey: ["rental_contracts", "customer", customerId],
    queryFn: () => rentals.listCustomerRentalContracts(customerId!),
    enabled: !!customerId,
  })
}

export function useCreateRental() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateRentalInput) => rentals.createRental(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["rental_contracts"] })
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
      qc.invalidateQueries({ queryKey: ["customers"] })
    },
  })
}

export function useMarkRentalReturned() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, contractId }: { orgId: string; contractId: string }) => rentals.markRentalReturned(orgId, contractId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["rental_contracts"] })
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
    },
  })
}
