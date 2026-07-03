import { useEffect, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tech from "@/services/technician"
import { useProfile } from "@/hooks/useProfile"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { subscribeSyncState } from "@/lib/offline/sync"
import { watchPendingCount } from "@/lib/offline/outbox"
import type { Enums } from "@/types/database"

const todayIso = () => new Date().toISOString().slice(0, 10)

export function useMyTechnician() {
  const { data: profile } = useProfile()
  return useQuery({
    queryKey: ["technicians", "me", profile?.id],
    queryFn: () => tech.getMyTechnician(profile!.id),
    enabled: !!profile?.id && profile.role === "technician",
    staleTime: 5 * 60_000,
  })
}

export function useTechnicianSettings(orgId: string | undefined) {
  return useQuery({
    queryKey: ["settings", "technician", orgId],
    queryFn: () => tech.getSettings(orgId!),
    enabled: !!orgId,
    staleTime: 60_000,
  })
}

/** Live pending-sync count + last sync state, for a small status chip in the shell. */
export function useSyncStatus() {
  const [pending, setPending] = useState(0)
  const [syncState, setSyncState] = useState(() => ({ syncing: false, lastError: null as string | null, lastSyncedAt: null as number | null }))

  useEffect(() => {
    const unwatch = watchPendingCount(setPending)
    const unsub = subscribeSyncState(setSyncState)
    return () => {
      unwatch()
      unsub()
    }
  }, [])

  return { pending, ...syncState }
}

// ── TECH-01 Attendance ───────────────────────────────────────────────────

export function useTodayAttendance(technicianId: string | undefined) {
  const date = todayIso()
  return useQuery({
    queryKey: ["attendance", "today", technicianId, date],
    queryFn: () => tech.getTodayAttendance(technicianId!, date),
    enabled: !!technicianId,
  })
}

export function useMarkAttendance() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: tech.MarkAttendanceInput) => tech.queueMarkAttendance(input),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["attendance", "today"] }),
  })
}

export function useLunchToggle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ technicianId, date, patch }: { technicianId: string; date: string; patch: { lunch_start: string } | { lunch_end: string } }) =>
      tech.queueLunchToggle(technicianId, date, patch),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["attendance", "today"] }),
  })
}

export function useLogCall() {
  return useMutation({ mutationFn: tech.logCall })
}

// ── TECH-02 Spare receipt ────────────────────────────────────────────────

export function useTodayHandover(technicianId: string | undefined) {
  const date = todayIso()
  return useQuery({
    queryKey: ["spareHandovers", "today", technicianId, date],
    queryFn: () => tech.getTodayHandover(technicianId!, date),
    enabled: !!technicianId,
  })
}

export function useConfirmHandover() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ handoverId, techSignUrl, adminSignUrl }: { handoverId: string; techSignUrl: string; adminSignUrl: string }) =>
      tech.queueConfirmHandover(handoverId, techSignUrl, adminSignUrl),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["spareHandovers", "today"] }),
  })
}

// ── TECH-03 Home ─────────────────────────────────────────────────────────

export function useTodaysJobs(technicianId: string | undefined) {
  return useQuery({
    queryKey: ["jobs", "today", technicianId],
    queryFn: () => tech.listTodaysJobs(technicianId!),
    enabled: !!technicianId,
    refetchInterval: 60_000,
  })
}

// ── TECH-04/05/06 ─────────────────────────────────────────────────────────

export function useJobDetail(ticketId: string | undefined) {
  return useQuery({
    queryKey: ["jobDetail", ticketId],
    queryFn: () => tech.getJobDetail(ticketId!),
    enabled: !!ticketId,
  })
}

export function useCustomerHistory(customerId: string | undefined, excludeTicketId?: string) {
  return useQuery({
    queryKey: ["customerHistory", customerId, excludeTicketId],
    queryFn: () => tech.getCustomerHistory(customerId!, excludeTicketId),
    enabled: !!customerId,
  })
}

export function useAddressSearch(orgId: string | undefined, term: string) {
  const debounced = useDebouncedValue(term, 300)
  return useQuery({
    queryKey: ["addresses", "techSearch", orgId, debounced],
    queryFn: () => tech.searchAddressesForTechnician(orgId!, debounced),
    enabled: !!orgId && debounced.trim().length > 1,
  })
}

export function useQueueLocationPing() {
  return useMutation({
    mutationFn: ({ orgId, technicianId, lat, lng }: { orgId: string; technicianId: string; lat: number; lng: number }) =>
      tech.queueLocationPing(orgId, technicianId, lat, lng),
  })
}

// ── TECH-07 On-site stepper ───────────────────────────────────────────────

export function useStartVisit() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: tech.queueStartVisit,
    onSuccess: () => qc.invalidateQueries({ queryKey: ["jobs", "today"] }),
  })
}

export function useQueueVisitImage() {
  return useMutation({
    mutationFn: ({ visitId, kind, url }: { visitId: string; kind: "before" | "after"; url: string }) =>
      tech.queueVisitImage(visitId, kind, url),
  })
}

/** Closes the visit's productivity timer once payment completes (TECH-07 step 10 -> TECH-08 handoff). */
export function useEndVisit() {
  return useMutation({
    mutationFn: ({ visitId, timerEnd }: { visitId: string; timerEnd: string }) => tech.queueEndVisit(visitId, timerEnd),
  })
}

/** Persists a captured on-screen signature locally (see cacheVisitSignature doc — no server column exists yet). */
export function useCacheVisitSignature() {
  return useMutation({
    mutationFn: ({ visitId, kind, dataUrl }: { visitId: string; kind: "signature_tech" | "signature_customer"; dataUrl: string }) =>
      tech.cacheVisitSignature(visitId, kind, dataUrl),
  })
}

export function useQueueSopStepComplete() {
  return useMutation({ mutationFn: tech.queueSopStepComplete })
}

export function useQueueRoChecklist() {
  return useMutation({ mutationFn: tech.queueRoChecklist })
}

export function useSpareSearch(orgId: string | undefined, term: string) {
  const debounced = useDebouncedValue(term, 250)
  return useQuery({
    queryKey: ["spares", "techSearch", orgId, debounced],
    queryFn: () => tech.searchSpares(orgId!, debounced),
    enabled: !!orgId,
  })
}

export function useCreateServiceInvoice() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: tech.queueCreateServiceInvoice,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["jobs", "today"] })
      qc.invalidateQueries({ queryKey: ["history"] })
    },
  })
}

export function useGenerateEnquiry() {
  return useMutation({ mutationFn: tech.queueGenerateEnquiry })
}

// ── TECH-08 Rating ─────────────────────────────────────────────────────────

export function useSubmitRating() {
  return useMutation({ mutationFn: tech.queueSubmitRating })
}

// ── TECH-09 History ────────────────────────────────────────────────────────

export function useMyHistory(technicianId: string | undefined, filters: { from?: string; to?: string; type?: Enums<"ticket_type"> }) {
  return useQuery({
    queryKey: ["history", "mine", technicianId, filters],
    queryFn: () => tech.listMyHistory(technicianId!, filters),
    enabled: !!technicianId,
  })
}

// ── TECH-10 Profile / stats ────────────────────────────────────────────────

export function useTechnicianStats(technicianId: string | undefined, orgId: string | undefined) {
  return useQuery({
    queryKey: ["technicianStats", technicianId],
    queryFn: () => tech.getTechnicianStats(technicianId!, orgId!),
    enabled: !!technicianId && !!orgId,
  })
}
