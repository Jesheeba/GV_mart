import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as api from "@/services/customerApp"
import * as catalogApi from "@/services/customerCatalog"
import * as enquiryConfigApi from "@/services/customerProductEnquiryConfig"
import type {
  AddressInput,
  EnquiryRpcInput,
  MyAmcContractRow,
  MyWarrantyRow,
  RenewAmcInput,
  ServiceBookingRpcInput,
} from "@/services/customerApp"
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

export type OwnedProductWithStatus = {
  product: MyOwnedProduct
  amc: MyAmcContractRow | undefined
  warranty: MyWarrantyRow | undefined
}

/**
 * Per-product union of ownership + current coverage status — the shared
 * source both CustomerProductsPage and CustomerAmcPage render into cards
 * (AMC page redesign). Built on useMyOwnedProducts, NOT useOwnedProducts
 * (the full org catalog), so a card can never be shown — and AMC can never
 * be booked — for a product this customer doesn't actually own.
 */
export function useOwnedProductsWithStatus(customerId: string | undefined) {
  const owned = useMyOwnedProducts(customerId)
  const amcContracts = useMyAmcContracts(customerId)
  const warranties = useMyWarranties(customerId)

  const data: OwnedProductWithStatus[] | undefined = owned.data
    ? owned.data.map((product) => ({
        product,
        amc: (amcContracts.data ?? []).find((c) => c.product_id === product.id),
        warranty: (warranties.data ?? []).find((w) => w.product_id === product.id),
      }))
    : undefined

  return {
    data,
    isLoading: owned.isLoading || amcContracts.isLoading || warranties.isLoading,
    isError: owned.isError || amcContracts.isError || warranties.isError,
    refetch: () => {
      owned.refetch()
      amcContracts.refetch()
      warranties.refetch()
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
// Customer Dashboard Booking Audit (2026-07-31) Tasks 2-4.

export function useAppointmentSlots(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "appointmentSlots", orgId],
    queryFn: () => api.listAppointmentSlots(orgId!),
    enabled: !!orgId,
    staleTime: 5 * 60_000,
  })
}

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

// Task 4 — resolve-on-view, best-effort. Fire from a page mount; never
// surfaces an error (a missed sweep just runs again next view).
export function useResolveStaleBookings(orgId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: () => api.resolveStaleBookings(orgId!),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "tickets"] }),
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

// ── Bookings / History (CUST-07, Task 7 2026-07-30 server-side filters) ──

export function useMyTicketsFiltered(customerId: string | undefined, filters: api.TicketFilters, page: number) {
  return useQuery({
    queryKey: ["customerApp", "tickets", customerId, filters, page],
    queryFn: () => api.listMyTicketsFiltered(filters, page),
    enabled: !!customerId,
    placeholderData: (prev) => prev,
    refetchInterval: 30_000,
  })
}

export function useMyTicketTechnicians(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "ticketTechnicians", customerId],
    queryFn: () => api.listMyTicketTechnicians(),
    enabled: !!customerId,
    staleTime: 5 * 60_000,
  })
}

export function useActiveAssignedTickets(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "activeAssignedTickets", customerId],
    queryFn: () => api.listActiveAssignedTickets(),
    enabled: !!customerId,
    refetchInterval: 20_000,
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

export function useMyAmcContractHistory(customerId: string | undefined, productId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "amcContractHistory", customerId, productId],
    queryFn: () => api.listMyAmcContractHistory(customerId!, productId!),
    enabled: !!customerId && !!productId,
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

// ── Product Enquiry rebuild (2026-08-04), Phase 3+ ──────────────────────
export function useProductEnquiryTabs(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "productEnquiryTabs", orgId],
    queryFn: () => enquiryConfigApi.listActiveProductEnquiryTabs(orgId!),
    enabled: !!orgId,
  })
}

export function useCatalogProducts(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "catalogProducts", orgId],
    queryFn: () => catalogApi.listCatalogProducts(orgId!),
    enabled: !!orgId,
  })
}

export function useProductDetail(productId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "productDetail", productId],
    queryFn: () => catalogApi.getCatalogProduct(productId!),
    enabled: !!productId,
  })
}

export function useCatalogProductsByIds(orgId: string | undefined, ids: string[]) {
  return useQuery({
    queryKey: ["customerApp", "catalogProductsByIds", orgId, ids],
    queryFn: () => catalogApi.listCatalogProductsByIds(orgId!, ids),
    enabled: !!orgId && ids.length > 0,
  })
}

export function useEffectiveProductCtas(orgId: string | undefined, productId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "effectiveProductCtas", orgId, productId],
    queryFn: () => enquiryConfigApi.listEffectiveProductCtas(orgId!, productId!),
    enabled: !!orgId && !!productId,
  })
}

export function useActiveProductAttributeKeys(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "activeProductAttributeKeys", orgId],
    queryFn: () => enquiryConfigApi.listActiveProductAttributeKeys(orgId!),
    enabled: !!orgId,
  })
}

export function useProductEnquiryFilters(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "productEnquiryFilters", orgId],
    queryFn: () => enquiryConfigApi.listActiveProductEnquiryFilters(orgId!),
    enabled: !!orgId,
  })
}

export function useProductEnquiryComparisonFields(orgId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "productEnquiryComparisonFields", orgId],
    queryFn: () => enquiryConfigApi.listActiveProductEnquiryComparisonFields(orgId!),
    enabled: !!orgId,
  })
}

// Task 6 (2026-07-30) — spares mapped to the selected product, for the
// Spare Enquiry picker.
export function useSparesForProduct(productId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "sparesForProduct", productId],
    queryFn: () => api.listSparesForProduct(productId!),
    enabled: !!productId,
  })
}

export function useSubmitEnquiry() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: EnquiryRpcInput) => api.submitCustomerEnquiry(input),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["customerApp", "leads"] }),
  })
}

// Product Enquiry rebuild (2026-08-04) Phase 4.
export function useRequestCallback() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (input: api.CallbackRpcInput) => api.requestCallback(input),
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

export function useTechnicianPublicStats(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["customerApp", "technicianPublicStats", technicianId],
    queryFn: () => api.getTechnicianPublicStats(technicianId!),
    enabled: !!technicianId,
    staleTime: 5 * 60_000,
  })
}

export function useSubmitCustomerRating() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: api.submitCustomerRating,
    // Also refetch on error: the most common failure is the technician having
    // already collected this visit's rating in person (ratings.visit_id is
    // unique — one rating total). Re-fetching swaps the stale empty form for
    // the real rating instead of leaving the customer stuck retrying forever.
    onSettled: () => qc.invalidateQueries({ queryKey: ["customerApp", "ticketDetail"] }),
  })
}
