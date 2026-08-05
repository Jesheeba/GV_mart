import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as paymentService from "@/services/paymentService"
import type { TablesInsert } from "@/types/database"

/** Admin — mirrors useMasters.ts#useSettings/useUpdateSettings. */
export function usePaymentSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["paymentSettings", orgId],
    queryFn: () => paymentService.getPaymentSettings(orgId!),
    enabled: !!orgId,
  })
}

export function useUpdatePaymentSettings(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (patch: Omit<TablesInsert<"payment_settings">, "org_id">) => paymentService.upsertPaymentSettings(orgId!, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["paymentSettings", orgId] }),
  })
}

/** Customer — same table, scoped by the payment_settings_select_customer RLS policy. */
export function useCustomerPaymentSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["paymentSettings", "customer", orgId],
    queryFn: () => paymentService.getCustomerPaymentSettings(orgId!),
    enabled: !!orgId,
  })
}
