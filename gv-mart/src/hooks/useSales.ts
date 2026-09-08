import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as sales from "@/services/sales"
import type { Enums } from "@/types/database"
import { triggerWaDispatchNow } from "@/services/whatsapp"

export function useCreateSale() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: {
      orgId: string
      customerId: string
      cart: sales.SaleCart
      quotationId?: string | null
      referredByTechnicianId?: string | null
      amountPaid?: number | null
    }) =>
      sales.createSale(
        input.orgId,
        input.customerId,
        input.cart,
        input.quotationId,
        input.referredByTechnicianId,
        input.amountPaid
      ),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["invoices"] })
      qc.invalidateQueries({ queryKey: ["inventory", "list"] })
      qc.invalidateQueries({ queryKey: ["quotations"] })
      qc.invalidateQueries({ queryKey: ["customers", "referralBalance"] })
      triggerWaDispatchNow()
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

export function useRecordAdditionalPayment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: {
      orgId: string
      invoiceId: string
      amount: number
      paymentMethod: Enums<"payment_method">
      txnId?: string | null
      paymentDescription?: string | null
    }) =>
      sales.recordAdditionalPayment(input.orgId, input.invoiceId, input.amount, input.paymentMethod, input.txnId, input.paymentDescription),
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: ["invoices", "detail", variables.invoiceId] })
      qc.invalidateQueries({ queryKey: ["invoices", "list"] })
    },
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

export function useUpdateOrganization(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (patch: { gst_no: string | null; address: string | null; phone: string | null; business_hours: string | null }) =>
      sales.updateOrganization(orgId!, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["organizations", "detail", orgId] }),
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
