import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as service from "@/services/service"
import type { CreateComplaintInput, TicketFiltersInput } from "@/services/service"

export function useTicketsList(orgId: string | undefined, filters: TicketFiltersInput) {
  return useQuery({
    queryKey: ["service_tickets", "list", orgId, filters],
    queryFn: () => service.listTickets(orgId!, filters),
    enabled: !!orgId,
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
