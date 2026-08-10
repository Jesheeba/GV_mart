import { useEffect } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { supabase } from "@/lib/supabase"
import * as service from "@/services/service"
import type { CreateComplaintInput, TicketFiltersInput } from "@/services/service"
import * as ticketPhotos from "@/services/ticketPhotos"
import { listPaymentProofsByInvoice } from "@/services/paymentProofs"

/**
 * Admin-side counterpart to the "nothing is flagged" gap: the job
 * board/tickets list/appointments range previously only refreshed on manual
 * navigation or reload. `service_tickets` is already realtime-published
 * (customer app's TechnicianAssignedBanner), and both auto-assign paths
 * update it (`status = 'assigned'`) in the same transaction as setting the
 * appointment's technician_id, so subscribing here and invalidating both
 * query namespaces is enough to reflect a fresh assignment live — no need to
 * separately publish `appointments`. Mount once, shell-level (AdminShell),
 * so every admin screen benefits.
 */
export function useServiceTicketsRealtimeInvalidate(orgId: string | undefined) {
  const queryClient = useQueryClient()

  useEffect(() => {
    if (!orgId) return
    const channel = supabase
      .channel(`admin-service-tickets-alerts-${orgId}`)
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "service_tickets", filter: `org_id=eq.${orgId}` }, () => {
        void queryClient.invalidateQueries({ queryKey: ["service_tickets"] })
        void queryClient.invalidateQueries({ queryKey: ["appointments"] })
      })
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [orgId, queryClient])
}

export function useTicketsList(orgId: string | undefined, filters: TicketFiltersInput) {
  return useQuery({
    queryKey: ["service_tickets", "list", orgId, filters],
    queryFn: () => service.listTickets(orgId!, filters),
    enabled: !!orgId,
  })
}

/** Header search dropdown's ticket half — see service.ts#searchTicketsQuick. */
export function useTicketSearch(orgId: string | undefined, term: string) {
  return useQuery({
    queryKey: ["service_tickets", "quickSearch", orgId, term],
    queryFn: () => service.searchTicketsQuick(orgId!, term),
    enabled: !!orgId && term.trim().length > 0,
    staleTime: 10_000,
  })
}

export function useTicket(id: string | undefined) {
  return useQuery({
    queryKey: ["service_tickets", "detail", id],
    queryFn: () => service.getTicket(id!),
    enabled: !!id,
  })
}

export function useUpdateTicketAddress() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ ticketId, addressId }: { ticketId: string; addressId: string | null }) => service.updateTicketAddress(ticketId, addressId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["service_tickets"] }),
  })
}

/**
 * Gate-assignment-on-product — see service.ts#updateTicketProduct.
 * `retry: 2` overrides the app-wide `retry: 0` default (queryClient.ts) —
 * safe here specifically because this write is a plain idempotent
 * `.update().eq(id)` (re-applying the same product/brand/model is a no-op),
 * unlike most mutations in this app which have real side effects and must
 * never auto-retry. Added because a transient fetch failure here otherwise
 * strands the admin on a picker that "did nothing" with no way to tell a
 * real error from a dropped request.
 */
export function useUpdateTicketProduct() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({
      ticketId,
      productId,
      brandId,
      modelId,
      unlistedProductName,
    }: {
      ticketId: string
      productId: string | null
      brandId: string | null
      modelId: string | null
      unlistedProductName: string | null
    }) => service.updateTicketProduct(ticketId, { productId, brandId, modelId, unlistedProductName }),
    retry: 2,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["service_tickets"] }),
  })
}

/** Gate-assignment-on-product — feeds the Dashboard/Masters nag. */
export function useTicketsMissingProduct(orgId: string | undefined) {
  return useQuery({
    queryKey: ["service_tickets", "missingProduct", orgId],
    queryFn: () => service.listTicketsMissingProduct(orgId!),
    enabled: !!orgId,
    refetchInterval: 30_000,
  })
}

/** Build Order A4 — see service.ts#updateTicketEstimatedDuration. */
export function useUpdateTicketEstimatedDuration() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ ticketId, minutes }: { ticketId: string; minutes: number | null }) => service.updateTicketEstimatedDuration(ticketId, minutes),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["service_tickets"] }),
  })
}

export function useRepeatComplaintCustomers(orgId: string | undefined) {
  return useQuery({
    queryKey: ["service_tickets", "repeatComplaints", orgId],
    queryFn: () => service.customersWithRepeatComplaints(orgId!),
    enabled: !!orgId,
    staleTime: 60_000,
  })
}

export function useDetectTicketType(orgId: string | undefined, customerId: string, productId: string | null) {
  return useQuery({
    queryKey: ["service_tickets", "detectType", orgId, customerId, productId],
    queryFn: () => service.detectTicketType(orgId!, customerId, productId),
    enabled: !!orgId && !!customerId,
  })
}

export function useCreateComplaintTicket() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: CreateComplaintInput) => service.createComplaintTicket(input),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useAutoAssignTicket() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ticketId: string) => service.autoAssignTicket(ticketId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useAssignTicketTechnician() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ appointmentId, technicianId, force }: { appointmentId: string; technicianId: string; force?: boolean }) =>
      service.assignTicketTechnician(appointmentId, technicianId, force),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useLogConfirmedAvailability() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: service.logConfirmedAvailability,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useUnassignAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (appointmentId: string) => service.unassignAppointment(appointmentId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useCompleteAppointment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (appointmentId: string) => service.completeAppointment(appointmentId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useCancelServiceTicket() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ ticketId, reason }: { ticketId: string; reason: string }) => service.cancelServiceTicket(ticketId, reason),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

export function useDeleteServiceTicket() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (ticketId: string) => service.deleteServiceTicket(ticketId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["service_tickets"] })
      qc.invalidateQueries({ queryKey: ["appointments"] })
    },
  })
}

/** GV.md §2 admin override — see service.ts#adminOverrideVisitCompletion. */
export function useAdminOverrideVisitCompletion() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, visitId, reason }: { orgId: string; visitId: string; reason: string }) =>
      service.adminOverrideVisitCompletion(orgId, visitId, reason),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["service_tickets"] }),
  })
}

export function useUpdateAppointmentSchedule() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, patch }: { id: string; patch: Parameters<typeof service.updateAppointmentSchedule>[1] }) =>
      service.updateAppointmentSchedule(id, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["appointments"] }),
  })
}

export function useTechnicians(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "list", orgId],
    queryFn: () => service.listTechnicians(orgId!),
    enabled: !!orgId,
  })
}

export function useAppointmentsRange(orgId: string | undefined, fromDate: string, toDate: string) {
  return useQuery({
    queryKey: ["appointments", "range", orgId, fromDate, toDate],
    queryFn: () => service.listAppointments(orgId!, fromDate, toDate),
    enabled: !!orgId,
  })
}

export function useOwnedEquipment(orgId: string | undefined, customerId: string | undefined) {
  return useQuery({
    queryKey: ["service_tickets", "ownedEquipment", orgId, customerId],
    queryFn: () => service.listOwnedEquipment(orgId!, customerId!),
    enabled: !!orgId && !!customerId,
  })
}

export function useCustomerAddresses(customerId: string | undefined) {
  return useQuery({
    queryKey: ["addresses", "byCustomer", customerId],
    queryFn: () => service.listCustomerAddresses(customerId!),
    enabled: !!customerId,
  })
}

export function useSlaSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["settings", "sla", orgId],
    queryFn: () => service.getSlaSettings(orgId!),
    enabled: !!orgId,
    staleTime: 60_000,
  })
}

/** Runs the SLA-breach / stuck-handover scan (see refresh_operational_alerts SQL), same
 *  "mutate once per org on page load" shape as useAmc.ts#useRefreshAmcStatuses. */
export function useRefreshOperationalAlerts(orgId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => service.refreshOperationalAlerts(orgId!),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["notifications"] }),
  })
}

/** Admin "Evidence" card on TicketDetailPage (Bug 7 / UI Suggestion 4) — a
 *  separate, independently-loading query from useTicket so the page's fast
 *  3-card view isn't blocked on this heavier per-visit fetch. */
export function useTicketEvidence(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["service_tickets", "evidence", ticketId],
    queryFn: () => service.getTicketEvidence(ticketId!),
    enabled: !!ticketId,
  })
}

// ── Gate-assignment-on-product (2026-08-04): optional customer photo(s) ───
// attached when booking with "I don't know the product" — see ticketPhotos.ts.

export function useTicketPhotos(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["service_ticket_photos", ticketId],
    queryFn: () => ticketPhotos.listTicketPhotos(ticketId!),
    enabled: !!ticketId,
  })
}

export function useUploadTicketPhoto() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, ticketId, file }: { orgId: string; ticketId: string; file: File }) =>
      ticketPhotos.uploadTicketPhoto(orgId, ticketId, file),
    onSuccess: (_data, variables) => qc.invalidateQueries({ queryKey: ["service_ticket_photos", variables.ticketId] }),
  })
}

// Enhancement spec Task 2 — UPI payment proofs for the admin Customer
// History / Booking Details view, see services/paymentProofs.ts.
export function usePaymentProofs(invoiceId: string | undefined) {
  return useQuery({
    queryKey: ["payment_proofs", invoiceId],
    queryFn: () => listPaymentProofsByInvoice(invoiceId!),
    enabled: !!invoiceId,
  })
}
