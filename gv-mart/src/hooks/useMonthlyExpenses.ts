import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as monthlyExpenses from "@/services/monthlyExpenses"
import type { DateRange } from "@/services/reports"

// Monthly Expenses spec (GVMART_MONTHLY_EXPENSES_SPEC.md) — thin React Query
// wrappers, same shape as useTechniciansAdmin.ts.

export function useTechnicianVehicleHistory(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["technician_vehicles", technicianId],
    queryFn: () => monthlyExpenses.listTechnicianVehicleHistory(technicianId!),
    enabled: !!technicianId,
  })
}

export function useSetTechnicianVehicle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof monthlyExpenses.setTechnicianVehicle>[0]) => monthlyExpenses.setTechnicianVehicle(input),
    onSuccess: (_data, variables) => qc.invalidateQueries({ queryKey: ["technician_vehicles", variables.technician_id] }),
  })
}

export function useCloseTechnicianVehicleRow() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, effectiveTo }: { id: string; effectiveTo: string; technicianId: string }) =>
      monthlyExpenses.closeTechnicianVehicleRow(id, effectiveTo),
    onSuccess: (_data, variables) => qc.invalidateQueries({ queryKey: ["technician_vehicles", variables.technicianId] }),
  })
}

export function useTechnicianOwnBikeDays(orgId: string | undefined, technicianId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["technician_vehicles", "ownBikeDays", orgId, technicianId, period],
    queryFn: () => monthlyExpenses.getTechnicianOwnBikeDays(orgId!, technicianId!, period),
    enabled: !!orgId && !!technicianId,
  })
}

export function useKmLogEntries(technicianId: string | undefined, range: DateRange | undefined) {
  return useQuery({
    queryKey: ["technician_km_log", technicianId, range],
    queryFn: () => monthlyExpenses.listKmLogEntries(technicianId!, range!),
    enabled: !!technicianId && !!range,
  })
}

export function useAddKmLogEntry() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof monthlyExpenses.addKmLogEntry>[0]) => monthlyExpenses.addKmLogEntry(input),
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: ["technician_km_log", variables.technician_id] })
    },
  })
}

export function useKmLogMonthlySum(orgId: string | undefined, technicianId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["technician_km_log", "monthlySum", orgId, technicianId, period],
    queryFn: () => monthlyExpenses.getKmLogMonthlySum(orgId!, technicianId!, period),
    enabled: !!orgId && !!technicianId,
  })
}

export function useApproxDistanceKm(orgId: string | undefined, technicianId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["technician_km_log", "approxDistance", orgId, technicianId, period],
    queryFn: () => monthlyExpenses.getApproxDistanceKm(orgId!, technicianId!, period),
    enabled: !!orgId && !!technicianId,
  })
}

export function usePetrolReferenceAmount(orgId: string | undefined, technicianId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["technician_km_log", "petrolReference", orgId, technicianId, period],
    queryFn: () => monthlyExpenses.getPetrolReferenceAmount(orgId!, technicianId!, period),
    enabled: !!orgId && !!technicianId,
  })
}

export function useSubmitExpenseClaim() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof monthlyExpenses.submitExpenseClaim>[0]) => monthlyExpenses.submitExpenseClaim(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["expense_claims"] }),
  })
}

export function useVerifyExpenseClaim() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ claimId, verifiedAmount, reason }: { claimId: string; verifiedAmount: number; reason: string | null }) =>
      monthlyExpenses.verifyExpenseClaim(claimId, verifiedAmount, reason),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["expense_claims"] }),
  })
}

export function usePendingExpenseClaims(orgId: string | undefined) {
  return useQuery({
    queryKey: ["expense_claims", "pending", orgId],
    queryFn: () => monthlyExpenses.listExpenseClaimsForVerification(orgId!),
    enabled: !!orgId,
  })
}

export function useMyExpenseClaims(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["expense_claims", "mine", technicianId],
    queryFn: () => monthlyExpenses.listMyExpenseClaims(technicianId!),
    enabled: !!technicianId,
  })
}

export function usePersonAllowanceHistory(profileId: string | undefined) {
  return useQuery({
    queryKey: ["person_allowances", profileId],
    queryFn: () => monthlyExpenses.listPersonAllowanceHistory(profileId!),
    enabled: !!profileId,
  })
}

export function useSetPersonAllowance() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof monthlyExpenses.setPersonAllowance>[0]) => monthlyExpenses.setPersonAllowance(input),
    onSuccess: (_data, variables) => qc.invalidateQueries({ queryKey: ["person_allowances", variables.profile_id] }),
  })
}

export function useClosePersonAllowanceRow() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, effectiveTo }: { id: string; effectiveTo: string; profileId: string }) =>
      monthlyExpenses.closePersonAllowanceRow(id, effectiveTo),
    onSuccess: (_data, variables) => qc.invalidateQueries({ queryKey: ["person_allowances", variables.profileId] }),
  })
}

export function useAddMonthlyAdjustment() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: Parameters<typeof monthlyExpenses.addMonthlyAdjustment>[0]) => monthlyExpenses.addMonthlyAdjustment(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["monthly_adjustments"] }),
  })
}

export function useMonthlyAdjustments(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["monthly_adjustments", orgId, period],
    queryFn: () => monthlyExpenses.listMonthlyAdjustments(orgId!, period),
    enabled: !!orgId,
  })
}

export function useMonthlyExpensesReport(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["monthly_expenses_report", orgId, period],
    queryFn: () => monthlyExpenses.getMonthlyExpensesReport(orgId!, period),
    enabled: !!orgId,
  })
}
