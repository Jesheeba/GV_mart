// Derives a customer-facing tracking stage purely client-side. The schema
// has no "heading_to_you"/"nearby"/"arrived" status columns anywhere
// (ticket_status is open/assigned/in_progress/completed/cancelled,
// appointment_status is scheduled/in_progress/completed/cancelled) — see
// the live-tracking plan's research: appointments.status only flips to
// 'in_progress' once service_visits.timer_start is set (arrival/visit
// start), not when a technician departs. So "on the way" vs "nearby" is
// derived entirely from live GPS distance, same proxy the technician's own
// arrival-geofence logic already uses (MapPage.tsx's ARRIVAL_GEOFENCE_RADIUS_M).

export type TrackingStage = "booking_confirmed" | "technician_assigned" | "heading_to_you" | "nearby" | "arrived_working" | "completed" | "cancelled"

/** Spec calls for "nearby" around ~500m. */
export const NEARBY_THRESHOLD_KM = 0.5

/** Ordered for the timeline UI — "technician_assigned" through "nearby" collapse into one visual step ("heading_to_you") since they share a timeline dot; kept as distinct stage VALUES above because the status chip/ETA card still want the finer distinction. */
export const TIMELINE_STAGES: TrackingStage[] = ["booking_confirmed", "technician_assigned", "heading_to_you", "arrived_working", "completed"]

export type TrackingStageInput = {
  ticketStatus: "open" | "assigned" | "in_progress" | "completed" | "cancelled"
  hasTechnician: boolean
  /** service_visits.timer_start is set (technician has started the visit). */
  visitStarted: boolean
  /** service_visits.timer_end is set (visit closed — via OTP or admin override). */
  visitEnded: boolean
  distanceKm: number | null
}

export function deriveTrackingStage(input: TrackingStageInput): TrackingStage {
  if (input.ticketStatus === "cancelled") return "cancelled"
  if (input.ticketStatus === "completed" || input.visitEnded) return "completed"
  if (input.visitStarted) return "arrived_working"
  if (input.hasTechnician) {
    if (input.distanceKm != null && input.distanceKm <= NEARBY_THRESHOLD_KM) return "nearby"
    return "heading_to_you"
  }
  return "booking_confirmed"
}

/** Maps a stage to its position in TIMELINE_STAGES for progress-bar/timeline rendering — "nearby" renders as the same step as "heading_to_you". */
export function timelineIndexForStage(stage: TrackingStage): number {
  if (stage === "cancelled") return -1
  const normalized = stage === "nearby" ? "heading_to_you" : stage
  return TIMELINE_STAGES.indexOf(normalized)
}
