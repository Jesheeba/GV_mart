import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as workspace from "@/services/workspace"

// P3: the to-do/notifications hooks that used to live here (useMyWorkspaceTasks, useCreateTask, useSetTaskStatus,
// useMyNotificationsFeed, ...) moved to useTasks.ts (My Workspace merged into Tasks) or were retired outright —
// the dedicated Notifications pages never used useMyNotificationsFeed. What's left is appointment confirmation
// calls and the technician day-sheet, neither of which is a to-do list.

export function useUpcomingAppointmentsForConfirmation(orgId: string | undefined) {
  return useQuery({
    queryKey: ["appointments", "confirmationCall", "upcoming", orgId],
    queryFn: () => workspace.listUpcomingAppointmentsForConfirmation(orgId!),
    enabled: !!orgId,
  })
}

export function useMarkAppointmentConfirmed() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, userId, appointmentId, ticketLabel }: { orgId: string; userId: string; appointmentId: string; ticketLabel: string }) =>
      workspace.markAppointmentConfirmationCalled(orgId, userId, appointmentId, ticketLabel),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["appointments", "confirmationCall"] })
      qc.invalidateQueries({ queryKey: ["notifications"] })
    },
  })
}

export function useDaySheetSummary(orgId: string | undefined, technicianId: string | undefined) {
  return useQuery({
    queryKey: ["daySheet", "summary", orgId, technicianId],
    queryFn: () => workspace.getDaySheetSummary(orgId!, technicianId!),
    enabled: !!orgId && !!technicianId,
  })
}
