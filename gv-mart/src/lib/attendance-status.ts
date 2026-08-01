import type { StatusTone } from "@/components/shared/StatusDot"

/**
 * Admin Settings / Attendance audit, Task 2 — the 4-tier status computed
 * server-side by the `attendance_compute_status` trigger
 * (20260731190000_dynamic_attendance_status.sql), against LIVE
 * settings.work_start/late_cutoff/very_late_threshold_minutes at write time.
 * Every display site imports this instead of re-deriving a label/tone
 * locally, so a future 5th tier (or renamed label) only needs changing once.
 */
export type AttendanceStatus = "early" | "on_time" | "late" | "very_late"

export const ATTENDANCE_STATUS_TONE: Record<AttendanceStatus, StatusTone> = {
  early: "info",
  on_time: "success",
  late: "warning",
  very_late: "danger",
}

export const ATTENDANCE_STATUS_I18N_KEY: Record<AttendanceStatus, string> = {
  early: "technician.attendance.status.early",
  on_time: "technician.attendance.status.onTime",
  late: "technician.attendance.status.late",
  very_late: "technician.attendance.status.veryLate",
}
