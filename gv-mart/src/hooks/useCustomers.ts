import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as customers from "@/services/customers"
import type { CreateCustomerInput, CustomerListFilters, MemberRow } from "@/services/customers"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"

const MOBILE_REGEX = /^[6-9]\d{9}$/

export function useMobileDuplicateCheck(orgId: string | undefined, mobile: string, excludeCustomerId?: string) {
  const debounced = useDebouncedValue(mobile, 400)
  return useQuery({
    queryKey: ["customers", "duplicateCheck", orgId, debounced, excludeCustomerId],
    queryFn: () => customers.checkMobileInUse(orgId!, debounced, excludeCustomerId),
    enabled: !!orgId && MOBILE_REGEX.test(debounced),
  })
}

export function usePincodeLookup(orgId: string | undefined, pincode: string) {
  const debounced = useDebouncedValue(pincode, 300)
  return useQuery({
    queryKey: ["addresses", "pincodeLookup", orgId, debounced],
    queryFn: () => customers.lookupByPincode(orgId!, debounced),
    enabled: !!orgId && /^\d{6}$/.test(debounced),
  })
}

export function useCustomersList(orgId: string | undefined, filters: CustomerListFilters, page: number) {
  return useQuery({
    queryKey: ["customers", "list", orgId, filters, page],
    queryFn: () => customers.listCustomers(orgId!, filters, page),
    enabled: !!orgId,
    placeholderData: (prev) => prev,
  })
}

export function useCustomer(id: string | undefined) {
  return useQuery({
    queryKey: ["customers", "detail", id],
    queryFn: () => customers.getCustomer(id!),
    enabled: !!id,
  })
}

export function useCustomerFilterCounts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "filterCounts", orgId],
    queryFn: () => customers.getCustomerFilterCounts(orgId!),
    enabled: !!orgId,
  })
}

export function useCustomerListEnrichment(orgId: string | undefined, customerIds: string[]) {
  const key = [...customerIds].sort()
  return useQuery({
    queryKey: ["customers", "listEnrichment", orgId, key],
    queryFn: () => customers.getCustomerListEnrichment(orgId!, customerIds),
    enabled: !!orgId && customerIds.length > 0,
  })
}

export function useCustomerProducts(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "products", customerId],
    queryFn: () => customers.getCustomerProducts(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

export function useCustomerServiceHistory(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "serviceHistory", customerId],
    queryFn: () => customers.getCustomerServiceHistory(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

/**
 * Merged chronological timeline (service tickets + AMC contract events +
 * standalone invoices) for the customer detail page's Service History tab.
 * Kept alongside useCustomerServiceHistory (ticket-only) rather than
 * replacing it — see getCustomerTimeline's doc comment in services/customers.ts.
 */
export function useCustomerTimeline(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "timeline", customerId],
    queryFn: () => customers.getCustomerTimeline(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

export function useCustomerInvoices(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "invoices", customerId],
    queryFn: () => customers.getCustomerInvoices(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

export function useCustomerLifetimeSummary(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "lifetimeSummary", customerId],
    queryFn: () => customers.getCustomerLifetimeSummary(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

export function useCustomerAutocomplete(orgId: string | undefined, term: string) {
  return useQuery({
    queryKey: ["customers", "autocomplete", orgId, term],
    queryFn: () => customers.autocompleteCustomers(orgId!, term),
    enabled: !!orgId && term.trim().length > 0,
    staleTime: 10_000,
  })
}

export function useAreaAutocomplete(orgId: string | undefined, term: string) {
  return useQuery({
    queryKey: ["addresses", "areaAutocomplete", orgId, term],
    queryFn: () => customers.searchAreas(orgId!, term),
    enabled: !!orgId && term.trim().length > 0,
    staleTime: 30_000,
  })
}

export function useCreateCustomer() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateCustomerInput) => customers.createCustomerWithDetails(input),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customers", "list"] }),
  })
}

export function useUpdateCustomerProfession(customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (profession: string) => customers.updateCustomerProfession(customerId, profession),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}

export function useAddMember(orgId: string | undefined, customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (member: Parameters<typeof customers.addMember>[2]) => customers.addMember(orgId!, customerId, member),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}

export function useRemoveMember(customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (memberId: string) => customers.removeMember(memberId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}

export function useSetPrimaryMember(customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (memberId: string) => customers.setPrimaryMember(customerId, memberId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}

export function useMoveMemberOut(orgId: string | undefined, customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (member: MemberRow) => customers.moveMemberOut(orgId!, member),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}

// ── Exemption windows (B4, Build Order Step 4) ────────────────────────────

export function useCustomerExemptionWindows(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customers", "exemptionWindows", customerId],
    queryFn: () => customers.listExemptionWindows(customerId!),
    enabled: !!customerId,
  })
}

export function useAddExemptionWindow(orgId: string | undefined, customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof customers.addExemptionWindow>[2]) => customers.addExemptionWindow(orgId!, customerId, input),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customers", "exemptionWindows", customerId] }),
  })
}

export function useSetExemptionWindowActive(customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, isActive }: { id: string; isActive: boolean }) => customers.updateExemptionWindowActive(id, isActive),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customers", "exemptionWindows", customerId] }),
  })
}

export function useRemoveExemptionWindow(customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => customers.removeExemptionWindow(id),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customers", "exemptionWindows", customerId] }),
  })
}

export function useUpsertPrimaryAddress(orgId: string | undefined, customerId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: { existingAddressId: string | null; patch: Parameters<typeof customers.upsertPrimaryAddress>[3] }) =>
      customers.upsertPrimaryAddress(orgId!, customerId, input.existingAddressId, input.patch),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customers", "detail", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customers", "list"] })
    },
  })
}
