import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as quotations from "@/services/quotations"
import type { DateRange } from "@/services/reports"

export function useQuotationsList(orgId: string | undefined, dateRange?: DateRange, opts: { excludeTest?: boolean } = {}) {
  return useQuery({
    queryKey: ["quotations", "list", orgId, dateRange, opts],
    queryFn: () => quotations.listQuotations(orgId!, dateRange, opts),
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
      gstInclusive?: boolean | null
      noGst?: boolean
      discountAmount?: number
      discountReason?: string | null
    }) =>
      quotations.createQuotation(
        input.orgId,
        input.customerId,
        input.validUntil,
        input.items,
        input.leadId ?? null,
        input.gstInclusive ?? null,
        input.noGst ?? false,
        input.discountAmount ?? 0,
        input.discountReason ?? null
      ),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["quotations"] })
      // A direct quotation now opens a new lead + follow-up.
      qc.invalidateQueries({ queryKey: ["leads"] })
      qc.invalidateQueries({ queryKey: ["followups"] })
    },
  })
}

export function useMarkQuotationLost() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, reason }: { id: string; reason: string }) => quotations.markQuotationLost(id, reason),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["quotations"] }),
  })
}

export function useUpdateQuotation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: quotations.updateQuotation,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["quotations"] }),
  })
}

export function useQuotationRevisions(quotationId: string | undefined) {
  return useQuery({
    queryKey: ["quotations", "revisions", quotationId],
    queryFn: () => quotations.listQuotationRevisions(quotationId!),
    enabled: !!quotationId,
  })
}

export function useQuotationsForLead(leadId: string | undefined) {
  return useQuery({
    queryKey: ["quotations", "forLead", leadId],
    queryFn: () => quotations.listQuotationsForLead(leadId!),
    enabled: !!leadId,
  })
}
