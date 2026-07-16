import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as sales from "@/services/sales"

export function useCreateSale() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: { orgId: string; customerId: string; cart: sales.SaleCart; quotationId?: string | null }) =>
      sales.createSale(input.orgId, input.customerId, input.cart, input.quotationId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["invoices"] })
      qc.invalidateQueries({ queryKey: ["inventory", "list"] })
      qc.invalidateQueries({ queryKey: ["quotations"] })
      qc.invalidateQueries({ queryKey: ["customers", "referralBalance"] })
    },
  })
}

/** Customer's current spendable referral point balance (sum of the referral_points ledger). Used by NewSalePage to show/cap redemption — the authoritative check is still server-side inside create_sale. */
export function useCustomerReferralBalance(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "referralBalance", customerId],
    queryFn: () => sales.getCustomerReferralBalance(customerId!),
    enabled: !!customerId,
  })
}

export function useInvoicesList(orgId: string | undefined) {
  return useQuery({
    queryKey: ["invoices", "list", orgId],
    queryFn: () => sales.listInvoices(orgId!),
    enabled: !!orgId,
  })
}

export function useInvoice(orgId: string | undefined, id: string | undefined) {
  return useQuery({
    queryKey: ["invoices", "detail", id],
    queryFn: () => sales.getInvoice(orgId!, id!),
    enabled: !!orgId && !!id,
  })
}

export function useOrganization(orgId: string | undefined) {
  return useQuery({
    queryKey: ["organizations", "detail", orgId],
    queryFn: () => sales.getOrganization(orgId!),
    enabled: !!orgId,
    staleTime: 5 * 60_000,
  })
}

export function useInvoiceExtras(invoiceId: string | undefined) {
  return useQuery({
    queryKey: ["invoices", "extras", invoiceId],
    queryFn: async () => {
      const [warranties, tickets, amcContract] = await Promise.all([
        sales.getWarrantiesForInvoice(invoiceId!),
        sales.getTicketsForInvoice(invoiceId!),
        sales.getAmcContractForInvoice(invoiceId!),
      ])
      return { warranties, tickets, amcContract }
    },
    enabled: !!invoiceId,
  })
}
