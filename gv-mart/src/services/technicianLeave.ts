// Technician leave request in advance (KPI-protected). Spec: FEATURE_TECHNICIAN_LEAVE_REQUEST.md.
// Migration 20261106100000. All writes go through the SECURITY DEFINER RPCs below — there is no
// insert/update/delete RLS policy on technician_leave_requests, by design.
import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

// database.ts is hand-patched for this table (no codegen run — see its own comment there).
export type LeaveRequestRow = Tables<"technician_leave_requests">
export type LeaveRequestStatus = "pending" | "approved" | "rejected" | "cancelled" | "revoked"
export type LeaveDecision = "approved" | "rejected" | "revoked"

export type LeaveRequestListItem = LeaveRequestRow & {
  technicians: { id: string; profiles: { full_name: string } | null } | null
}

export async function requestTechnicianLeave(startDate: string, endDate: string, reason: string | null): Promise<LeaveRequestRow> {
  const { data, error } = await supabase.rpc("request_technician_leave" as never, {
    p_start_date: startDate,
    p_end_date: endDate,
    p_reason: reason,
  } as never)
  if (error) throw error
  return data as unknown as LeaveRequestRow
}

export async function cancelTechnicianLeave(requestId: string): Promise<LeaveRequestRow> {
  const { data, error } = await supabase.rpc("cancel_technician_leave" as never, { p_request_id: requestId } as never)
  if (error) throw error
  return data as unknown as LeaveRequestRow
}

export async function decideTechnicianLeave(requestId: string, decision: LeaveDecision, decisionNote: string | null): Promise<LeaveRequestRow> {
  const { data, error } = await supabase.rpc("decide_technician_leave" as never, {
    p_request_id: requestId,
    p_decision: decision,
    p_decision_note: decisionNote,
  } as never)
  if (error) throw error
  return data as unknown as LeaveRequestRow
}

/** Own requests only (RLS already restricts this to the caller's technician row). */
export async function listMyLeaveRequests(technicianId: string): Promise<LeaveRequestRow[]> {
  const { data, error } = await supabase
    .from("technician_leave_requests")
    .select("*")
    .eq("technician_id", technicianId)
    .order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as LeaveRequestRow[]
}

export async function listOrgLeaveRequests(orgId: string, filters: { status?: LeaveRequestStatus[] }): Promise<LeaveRequestListItem[]> {
  let query = supabase
    .from("technician_leave_requests")
    .select("*, technicians(id, profiles(full_name))")
    .eq("org_id", orgId)
  if (filters.status?.length) query = query.in("status", filters.status)
  const { data, error } = await query.order("status", { ascending: true }).order("created_at", { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as LeaveRequestListItem[]
}

export async function countPendingLeaveRequests(orgId: string): Promise<number> {
  const { count, error } = await supabase
    .from("technician_leave_requests")
    .select("*", { count: "exact", head: true })
    .eq("org_id", orgId)
    .eq("status", "pending")
  if (error) throw error
  return count ?? 0
}

export type AssignedVisitInRange = {
  appointment_id: string
  ticket_id: string
  scheduled_at: string
  customer_name: string | null
  name_of_complaint: string | null
}

/** Admin approve-time warning: the technician's already-assigned visits on the requested days. */
export async function listAssignedVisitsInRange(technicianId: string, startDate: string, endDate: string): Promise<AssignedVisitInRange[]> {
  const { data, error } = await supabase.rpc("technician_assigned_visits_in_range" as never, {
    p_technician_id: technicianId,
    p_start_date: startDate,
    p_end_date: endDate,
  } as never)
  if (error) throw error
  return (data ?? []) as unknown as AssignedVisitInRange[]
}

/** "Days excluded due to approved leave" on the technician table, for a given period. */
export async function getProtectedLeaveDays(orgId: string, technicianId: string, from: string, to: string): Promise<number> {
  const { data, error } = await supabase.rpc("technician_protected_leave_days" as never, {
    p_org_id: orgId,
    p_technician_id: technicianId,
    p_from: from,
    p_to: to,
  } as never)
  if (error) throw error
  return (data as unknown as number) ?? 0
}
