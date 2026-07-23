import { useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import * as tech from "@/services/technician"
import { useProfile } from "@/hooks/useProfile"
import { useDebouncedValue } from "@/hooks/useDebouncedValue"
import { subscribeSyncState } from "@/lib/offline/sync"
import { watchPendingCount, watchStuckJobs } from "@/lib/offline/outbox"
import { watchPosition } from "@/lib/offline/geo"
import type { Enums } from "@/types/database"
import type { OutboxJob } from "@/lib/offline/db"

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

/** Live list of outbox jobs that have failed enough times to stop auto-retrying (see sync.ts's MAX_ATTEMPTS_BEFORE_STUCK) — feeds the sync-status chip's stuck-jobs panel. */
export function useStuckJobs() {
  const [jobs, setJobs] = useState<OutboxJob[]>([])

  useEffect(() => {
    return watchStuckJobs(setJobs)
  }, [])

  return jobs
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

// onSuccess writes the mutation's own result straight into the query cache
// instead of invalidating (which would refetch over the network). The
// offline outbox only syncs to Supabase on its ~20s interval, so an
// immediate refetch would win the race and read back the stale pre-tap
// server row, making the tap appear not to register (see queueMarkAttendance
// doc comment in services/technician.ts).
export function useMarkAttendance() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (input: tech.MarkAttendanceInput) => tech.queueMarkAttendance(input),
    onSuccess: (row, variables) => qc.setQueryData(["attendance", "today", variables.technicianId, variables.date], row),
  })
}

export function useLunchToggle() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ technicianId, date, patch }: { technicianId: string; date: string; patch: { lunch_start: string } | { lunch_end: string } }) =>
      tech.queueLunchToggle(technicianId, date, patch),
    onSuccess: (row, variables) => {
      if (row) qc.setQueryData(["attendance", "today", variables.technicianId, variables.date], row)
    },
  })
}

export function useLogCall() {
  return useMutation({ mutationFn: tech.logCall })
}

/** Requirement 7 — mirrors useLunchToggle exactly, same setQueryData-not-invalidate reasoning (see its doc comment above / useMarkAttendance's). */
export function useCheckOut() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ technicianId, date }: { technicianId: string; date: string }) => tech.queueCheckOut(technicianId, date),
    onSuccess: (row, variables) => {
      if (row) qc.setQueryData(["attendance", "today", variables.technicianId, variables.date], row)
    },
  })
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

/** Requirement 6 — counts row (Today's Jobs/Pending/Completed/Cancelled/Overdue) on TechnicianHomePage. */
export function useTodaysJobCounts(orgId: string | undefined, technicianId: string | undefined) {
  return useQuery({
    queryKey: ["jobs", "todayCounts", orgId, technicianId],
    queryFn: () => tech.getTodaysJobCounts(orgId!, technicianId!),
    enabled: !!orgId && !!technicianId,
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

/**
 * Streams the technician's live GPS position to `technician_locations` for
 * the admin tracking map (v2.2 §6.6), for as long as the technician is
 * logged into the app — mounted once at the shell root in TechnicianShell so
 * it keeps running across every screen, not just while an active job exists
 * (the admin map already renders a neutral "no active job" marker for a
 * tracked technician with none — see TechniciansMapPage's "no-job" status —
 * so there's nothing to gate here; ETA/on-time logic is what's scoped to an
 * active job, not the position stream itself).
 * Throttled to one write per ~20s: watchPosition can fire far more often
 * than the admin map needs a fresh point, and every write is a Realtime
 * broadcast + DB row.
 */
export function useLiveLocationStream(orgId: string | undefined, technicianId: string | undefined) {
  const lastSentRef = useRef(0)
  useEffect(() => {
    if (!orgId || !technicianId) return
    lastSentRef.current = 0
    const stop = watchPosition((pos) => {
      const now = Date.now()
      if (now - lastSentRef.current < 20_000) return
      lastSentRef.current = now
      void tech.pingLiveLocation(orgId, technicianId, pos.lat, pos.lng)
    })
    return stop
  }, [orgId, technicianId])
}

// ── TECH-07 On-site stepper ───────────────────────────────────────────────

/**
 * A visit can be started from two independent places for the same job —
 * MapPage's arrival detection and OnSiteVisitPage's own mount effect (see
 * findOpenVisit's doc comment) — and both decide whether to start one by
 * reading the *cached* `["jobDetail", ticketId]` query. Without patching
 * that cache synchronously here, a technician who taps "Continue to
 * service" right after arriving could land on OnSiteVisitPage before the
 * network write lands, see the stale (pre-arrival) visit list, and create a
 * second, orphaned service_visits row. `onMutate` runs synchronously before
 * the write even starts, so the cache reflects the new open visit
 * immediately — no race window regardless of how fast the technician
 * navigates.
 *
 * Deliberately does NOT invalidate/refetch `["jobDetail", ticketId]` on
 * success: `queueStartVisit` enqueues the actual insert to the offline
 * outbox rather than writing it straight to Supabase (sync.ts flushes it on
 * a ~20s poll), so a refetch fired right after `onSuccess` almost always
 * lands before the real row exists server-side — it would overwrite this
 * correct optimistic entry with stale data that still shows no open visit,
 * which previously caused MapPage to flip back to "not arrived" and create
 * a duplicate visit once the confirm window re-ran. The optimistic patch
 * above is already the correct state; nothing needs to re-fetch it.
 */
export function useStartVisit() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: tech.queueStartVisit,
    onMutate: (visit) => {
      qc.setQueryData<tech.JobDetail>(["jobDetail", visit.ticketId], (prev) =>
        prev && !prev.service_visits.some((v) => v.id === visit.id)
          ? { ...prev, service_visits: [...prev.service_visits, { id: visit.id, timer_start: visit.timerStart, timer_end: null, service_charge: 0, before_image_url: null, after_image_url: null }] }
          : prev
      )
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ["jobs", "today"] }),
  })
}

export function useQueueVisitImage() {
  return useMutation({
    mutationFn: ({ visitId, kind, url }: { visitId: string; kind: "before" | "after"; url: string }) =>
      tech.queueVisitImage(visitId, kind, url),
  })
}

/** Closes the visit's productivity timer once payment completes (TECH-07 step 10 -> TECH-08 handoff). Optionally carries the technician's own visit notes through to `service_visits.notes` in the same patch. */
export function useEndVisit() {
  return useMutation({
    mutationFn: ({ visitId, timerEnd, notes }: { visitId: string; timerEnd: string; notes?: string }) => tech.queueEndVisit(visitId, timerEnd, notes),
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
