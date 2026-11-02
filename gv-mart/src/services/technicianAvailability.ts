// Urgent item #5 — availability-assisted scheduling for the master's
// create/assign-complaint flow. Backed by the read-only RPC
// get_technician_availability_for_date, migration
// 20261202100000_master_technician_availability_rpc.sql — NOT APPLIED yet
// (needs rehearsal + DRYRUN-OK + string review + owner APPROVED first, see
// that file's header). `as never` on the RPC name/args mirrors the exact
// pattern already used for other not-yet-codegenned RPCs in this repo
// (technicianLeave.ts's request_technician_leave etc.) — this isn't a new
// convention. Until the migration is applied, calls fail with Postgres
// 42883 (undefined function); callers should check that with
// isNotYetAvailableError (src/lib/supabaseErrors.ts), same as every other
// screen waiting on an unapplied migration in this codebase.
import { supabase } from "@/lib/supabase"
import type { TimeWindow } from "@/lib/booking-window"
import type { FreeGap, TechnicianAvailabilityRow } from "@/lib/technician-availability"

type RawRow = {
  technician_id: string
  technician_name: string
  is_on_leave: boolean
  work_start: string
  work_end: string
  busy_windows: TimeWindow[]
  free_windows: FreeGap[]
}

function toRow(r: RawRow): TechnicianAvailabilityRow {
  return {
    technicianId: r.technician_id,
    technicianName: r.technician_name,
    isOnLeave: r.is_on_leave,
    workStart: (r.work_start ?? "").slice(0, 5),
    workEnd: (r.work_end ?? "").slice(0, 5),
    busyWindows: (r.busy_windows ?? []).map((w) => ({ start: w.start.slice(0, 5), end: w.end.slice(0, 5) })),
    freeWindows: (r.free_windows ?? []).map((w) => ({ start: w.start.slice(0, 5), end: w.end.slice(0, 5), minutes: w.minutes })),
  }
}

/**
 * Date-first: every active technician in the org on `date`, each with their
 * busy/free windows and leave status — the master picks one from the list.
 */
export async function getTechniciansAvailabilityForDate(orgId: string, date: string): Promise<TechnicianAvailabilityRow[]> {
  const { data, error } = await supabase.rpc("get_technician_availability_for_date" as never, {
    p_org_id: orgId,
    p_date: date,
    p_technician_id: null,
  } as never)
  if (error) throw error
  return ((data ?? []) as unknown as RawRow[]).map(toRow)
}

/**
 * Technician-first: just the one technician's busy/free windows on `date` —
 * the master already picked them, now picks a free slot.
 */
export async function getTechnicianAvailabilityForDate(
  orgId: string,
  date: string,
  technicianId: string
): Promise<TechnicianAvailabilityRow | null> {
  const { data, error } = await supabase.rpc("get_technician_availability_for_date" as never, {
    p_org_id: orgId,
    p_date: date,
    p_technician_id: technicianId,
  } as never)
  if (error) throw error
  const rows = (data ?? []) as unknown as RawRow[]
  return rows.length > 0 ? toRow(rows[0]) : null
}
