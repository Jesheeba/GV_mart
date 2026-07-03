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
    mutationFn: (member: { name: string; mobile: string }) => customers.addMember(orgId!, customerId, member),
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
