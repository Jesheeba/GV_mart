import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as hr from "@/services/hr"
import type { LogRewardInput } from "@/services/hr"

export function useActiveTechnicians(orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicians", "active", orgId],
    queryFn: () => hr.listActiveTechnicians(orgId!),
    enabled: !!orgId,
  })
}

// ── Salary ─────────────────────────────────────────────────────────────────

export function useSalaries(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["salaries", "list", orgId, period],
    queryFn: () => hr.listSalaries(orgId!, period),
    enabled: !!orgId && !!period,
  })
}

export function useComputeSalary() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, technicianId, period }: { orgId: string; technicianId: string; period: string }) =>
      hr.computeSalary(orgId, technicianId, period),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["salaries"] }),
  })
}

// ── Incentives ─────────────────────────────────────────────────────────────

export function useIncentivesEarned(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["incentives_earned", "list", orgId, period],
    queryFn: () => hr.listIncentivesEarned(orgId!, period),
    enabled: !!orgId && !!period,
  })
}

export function useComputeIncentives() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ orgId, period }: { orgId: string; period: string }) => hr.computeIncentives(orgId, period),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["incentives_earned"] }),
  })
}

// ── Rewards ────────────────────────────────────────────────────────────────

export function useRewardCandidates(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["rewards", "candidates", orgId, period],
    queryFn: () => hr.getRewardCandidates(orgId!, period),
    enabled: !!orgId && !!period,
  })
}

export function useRewards(orgId: string | undefined, period: string) {
  return useQuery({
    queryKey: ["rewards", "list", orgId, period],
    queryFn: () => hr.listRewards(orgId!, period),
    enabled: !!orgId && !!period,
  })
}

export function useLogReward() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: LogRewardInput) => hr.logReward(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["rewards"] }),
  })
}
