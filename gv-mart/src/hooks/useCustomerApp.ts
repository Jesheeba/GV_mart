import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as api from "@/services/customerApp"
import type { AddressInput, EnquiryRpcInput, RenewAmcInput, ServiceBookingRpcInput } from "@/services/customerApp"
import { useProfile } from "@/hooks/useProfile"
import { supabase } from "@/lib/supabase"

/**
 * Resolves the signed-in customer's own `customers.id` (== current_customer_id()
 * server-side) via the profile's linked customer record. profiles.id is the
 * auth user id; customers.primary_profile_id points back at it 1:1.
 */
export function useMyCustomerId() {
  const { data: profile } = useProfile()
  const query = useQuery({
    queryKey: ["customerApp", "myCustomerId", profile?.id],
    queryFn: async () => {
      const { data, error } = await supabase.from("customers").select("id").eq("primary_profile_id", profile!.id).single()
      if (error) throw error
      return data.id as string
    },
    enabled: !!profile?.id && profile.role === "customer",
    staleTime: 5 * 60_000,
  })
  return { customerId: query.data, orgId: profile?.org_id, ...query }
}

export function useMyCustomerRecord(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "record", customerId],
    queryFn: () => api.getMyCustomerRecord(customerId!),
    enabled: !!customerId,
  })
}

export function useUpdateMyProfession(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (profession: string) => api.updateMyProfession(customerId!, profession),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] }),
  })
}

// ── Addresses ──────────────────────────────────────────────────────────────

export function useMyAddresses(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "addresses", customerId],
    queryFn: () => api.listMyAddresses(customerId!),
    enabled: !!customerId,
  })
}

export function useAddMyAddress(orgId: string | undefined, customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ input, makePrimary }: { input: AddressInput; makePrimary: boolean }) =>
      api.addMyAddress(orgId!, customerId!, input, makePrimary),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "addresses", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] })
    },
  })
}

export function useUpdateMyAddress(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ addressId, input }: { addressId: string; input: AddressInput }) => api.updateMyAddress(addressId, input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "addresses", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] })
    },
  })
}

export function useSetMyPrimaryAddress(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (addressId: string) => api.setMyPrimaryAddress(customerId!, addressId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "addresses", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] })
    },
  })
}

export function useDeleteMyAddress(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (addressId: string) => api.deleteMyAddress(addressId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "addresses", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] })
    },
  })
}

// ── Family members ─────────────────────────────────────────────────────────

export function useAddMyMember(orgId: string | undefined, customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (member: { name: string; mobile: string }) => api.addMyMember(orgId!, customerId!, member),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] }),
  })
}

export function useRemoveMyMember(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (memberId: string) => api.removeMyMember(memberId),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "record", customerId] }),
  })
}

// ── My Products (CUST-06) ──────────────────────────────────────────────────

export function useMyWarranties(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "warranties", customerId],
    queryFn: () => api.listMyWarranties(customerId!),
    enabled: !!customerId,
  })
}

export function useMyAmcContracts(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "amcContracts", customerId],
    queryFn: () => api.listMyAmcContracts(customerId!),
    enabled: !!customerId,
  })
}

// Despite the name, this is the org's full product catalog (no
// customer/ownership filter) — used for the QR-registration picker and as
// the "browse the full catalog" fallback in BookServicePage's product step.
// For the customer's actually-owned products, see useMyOwnedProducts below.
export function useOwnedProducts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "ownedProducts", orgId],
    queryFn: () => api.listOwnedProducts(orgId!),
    enabled: !!orgId,
  })
}

export type MyOwnedProduct = {
  id: string
  name: string
  category: string
  brands: { name: string } | null
  models: { name: string } | null
}

/**
 * The customer's real owned products — same warranty+AMC union
 * CustomerProductsPage already displays (a product counts as "owned" once
 * it has a warranty or AMC contract on file), deduplicated by product_id.
 * This is what "My Products" in the Book Service picker should show first,
 * per v2.2 §6.7 ("the existing product shows automatically") — unlike
 * useOwnedProducts above, which is actually the unfiltered catalog.
 */
export function useMyOwnedProducts(customerId: string | undefined) {
  const warranties = useMyWarranties(customerId)
  const amcContracts = useMyAmcContracts(customerId)
  const data =
    warranties.data && amcContracts.data
      ? (() => {
          const byProduct = new Map<string, MyOwnedProduct>()
          for (const w of warranties.data) {
            if (w.products && !byProduct.has(w.product_id)) byProduct.set(w.product_id, { id: w.product_id, ...w.products })
          }
          for (const a of amcContracts.data) {
            if (a.products && !byProduct.has(a.product_id)) byProduct.set(a.product_id, { id: a.product_id, ...a.products })
          }
          return Array.from(byProduct.values())
        })()
      : undefined
  return {
    data,
    isLoading: warranties.isLoading || amcContracts.isLoading,
    isError: warranties.isError || amcContracts.isError,
    refetch: () => {
      warranties.refetch()
      amcContracts.refetch()
    },
  }
}

export function useRegisterProductViaQr(orgId: string | undefined, customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ productId, serialNo, purchaseDate }: { productId: string; serialNo: string; purchaseDate: string | null }) =>
      api.registerProductViaQr(orgId!, productId, serialNo, purchaseDate),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "warranties", customerId] }),
  })
}

// ── Service Booking (CUST-02) ─────────────────────────────────────────────

export function useBookServiceTicket() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: ServiceBookingRpcInput) => api.bookServiceTicket(input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "tickets"] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "leads"] })
    },
  })
}

// B4 (Build Order Step 4): the customer's own standing exemption windows —
// shown as red, pre-populated "already blocked" entries in the booking
// wizard so they don't have to re-mark a school-run/medical window that's
// already on file (admin manages the actual list, see useCustomers.ts).
export function useMyExemptionWindows(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "exemptionWindows", customerId],
    queryFn: () => api.listMyExemptionWindows(customerId!),
    enabled: !!customerId,
  })
}

// ── Bookings / History (CUST-07) ──────────────────────────────────────────

export function useMyTickets(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "tickets", customerId],
    queryFn: () => api.listMyTickets(customerId!),
    enabled: !!customerId,
    refetchInterval: 30_000,
  })
}

export function useTicketDetail(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "ticketDetail", ticketId],
    queryFn: () => api.getTicketDetail(ticketId!),
    enabled: !!ticketId,
    refetchInterval: 20_000,
  })
}

// ── AMC (CUST-03) ──────────────────────────────────────────────────────────

export function useAmcPlans(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "amcPlans", orgId],
    queryFn: () => api.listAmcPlans(orgId!),
    enabled: !!orgId,
  })
}

export function useRenewAmcPlan(customerId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: RenewAmcInput) => api.renewAmcPlan(input),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["customerApp", "amcContracts", customerId] })
      queryClient.invalidateQueries({ queryKey: ["customerApp", "tickets", customerId] })
    },
  })
}

// ── Product / Spare Enquiry (CUST-04 / CUST-05) ───────────────────────────

export function useVideoLibrary(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "videoLibrary", orgId],
    queryFn: () => api.listVideoLibrary(orgId!),
    enabled: !!orgId,
  })
}

export function useSubmitEnquiry() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: EnquiryRpcInput) => api.submitCustomerEnquiry(input),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "leads"] }),
  })
}

// ── Referral wallet ─────────────────────────────────────────────────────────

export function useMyReferralPoints(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "referralPoints", customerId],
    queryFn: () => api.listMyReferralPoints(customerId!),
    enabled: !!customerId,
  })
}

// ── Settings ────────────────────────────────────────────────────────────────

export function useCustomerAppSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "settings", orgId],
    queryFn: () => api.getSettings(orgId!),
    enabled: !!orgId,
    staleTime: 5 * 60_000,
  })
}

// ── Live tracking ───────────────────────────────────────────────────────────

export function useLatestTechnicianLocation(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "technicianLocation", technicianId],
    queryFn: () => api.getLatestTechnicianLocation(technicianId!),
    enabled: !!technicianId,
  })
}
