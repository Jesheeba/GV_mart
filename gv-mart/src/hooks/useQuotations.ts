import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as quotations from "@/services/quotations"
import type { DateRange } from "@/services/reports"

export function useQuotationsList(orgId: string | undefined, dateRange?: DateRange) {
  return useQuery({
    queryKey: ["quotations", "list", orgId, dateRange],
    queryFn: () => quotations.listQuotations(orgId!, dateRange),
    enabled: !!orgId,
  })
}

export function useQuotation(orgId: string | undefined, id: string | undefined) {
  return useQuery({
    queryKey: ["quotations", "detail", id],
    queryFn: () => quotations.getQuotation(orgId!, id!),
    enabled: !!orgId && !!id,
  })
}

export function useCreateQuotation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: {
      orgId: string
      customerId: string | null
      leadId?: string | null
      validUntil: string | null
      items: quotations.QuotationCartItem[]
    }) => quotations.createQuotation(input.orgId, input.customerId, input.validUntil, input.items, input.leadId ?? null),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["quotations"] }),
  })
}

export function useMarkQuotationLost() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason: string }) => quotations.markQuotationLost(id, reason),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["quotations"] }),
  })
}
