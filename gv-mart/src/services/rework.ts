// Rework (build-docs/features/rework.md). Writes go only through SECURITY DEFINER RPCs; the
// service_tickets_rework_guard trigger refuses direct edits of the rework columns.
import { supabase } from "@/lib/supabase"
import { isWithinReworkWindow } from "@/lib/rework"
import type { Database, Enums } from "@/types/database"

export type MarkReworkInput = {
  ticketId: string
  reason: string
  scheduledDate: string
  unavailableWindows: { start: string; end: string }[]
  technicianId: string | null
}

export type MarkReworkResult = {
  rework_ticket_id: string
  responsible_technician_id: string
  assign_result: { assigned?: boolean; reason_key?: string; conflict_appointment_id?: string } | null
}

export async function markTicketRework(input: MarkReworkInput): Promise<MarkReworkResult> {
  const { data, error } = await supabase.rpc("mark_ticket_rework", {
    p_ticket_id: input.ticketId,
    p_reason: input.reason,
    p_scheduled_date: input.scheduledDate,
    p_unavailable_windows: input.unavailableWindows,
    p_technician_id: input.technicianId,
  })
  if (error) throw error
  return data as unknown as MarkReworkResult
}

export type ReworkCandidate = { id: string; nameOfComplaint: string | null; completedAt: string; technicianName: string | null }

/**
 * New-complaint suggestion: the latest completed ticket for this customer + product that is still inside
 * the rework window and has no live rework yet. null when there is none.
 */
export async function findReworkCandidate(
  orgId: string,
  customerId: string,
  productId: string,
  windowDays: number
): Promise<ReworkCandidate | null> {
  const since = new Date(Date.now() - windowDays * 86_400_000).toISOString()
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, name_of_complaint, updated_at, invoices:invoice_id(created_at), service_visits(timer_end, technicians(profiles(full_name)))")
    .eq("org_id", orgId)
    .eq("customer_id", customerId)
    .eq("product_id", productId)
    .eq("status", "completed")
    .gte("updated_at", since)
    .order("updated_at", { ascending: false })
    .limit(5)
  if (error) throw error
  type Row = {
    id: string
    name_of_complaint: string | null
    updated_at: string
    invoices: { created_at: string } | null
    service_visits: { timer_end: string | null; technicians: { profiles: { full_name: string } | null } | null }[]
  }
  const rows = (data ?? []) as unknown as Row[]
  const inWindow = rows.filter((r) => isWithinReworkWindow(r.invoices?.created_at ?? r.updated_at, windowDays))
  if (inWindow.length === 0) return null

  const { data: children, error: childErr } = await supabase
    .from("service_tickets")
    .select("rework_of_ticket_id")
    .in("rework_of_ticket_id", inWindow.map((r) => r.id))
    .neq("status", "cancelled")
  if (childErr) throw childErr
  const taken = new Set((children ?? []).map((c) => c.rework_of_ticket_id))
  const hit = inWindow.find((r) => !taken.has(r.id))
  if (!hit) return null
  const lastVisit = [...hit.service_visits].sort((a, b) => (b.timer_end ?? "").localeCompare(a.timer_end ?? ""))[0]
  return {
    id: hit.id,
    nameOfComplaint: hit.name_of_complaint,
    completedAt: hit.invoices?.created_at ?? hit.updated_at,
    technicianName: lastVisit?.technicians?.profiles?.full_name ?? null,
  }
}

/** The live (not cancelled) rework raised from a ticket, if any. */
export async function getReworkChild(ticketId: string): Promise<{ id: string; status: Enums<"ticket_status"> } | null> {
  const { data, error } = await supabase
    .from("service_tickets")
    .select("id, status")
    .eq("rework_of_ticket_id", ticketId)
    .neq("status", "cancelled")
    .maybeSingle()
  if (error) throw error
  return data
}

export async function requestReworkEscalation(ticketId: string, reason: string): Promise<string> {
  const { data, error } = await supabase.rpc("request_rework_escalation", { p_ticket_id: ticketId, p_reason: reason })
  if (error) throw error
  return data
}

/** The technician's own escalation for a rework ticket (approvals_select_own_request lets them read it). */
export async function getReworkEscalation(ticketId: string): Promise<{ id: string; status: Enums<"approval_status"> } | null> {
  const { data, error } = await supabase
    .from("approvals")
    .select("id, status")
    .eq("type", "rework")
    .eq("ref_id", ticketId)
    .maybeSingle()
  if (error) throw error
  return data
}

export type ReworkSummaryRow = Database["public"]["Functions"]["report_rework_summary"]["Returns"][number]

export async function reportReworkSummary(from: string, to: string): Promise<ReworkSummaryRow[]> {
  const { data, error } = await supabase.rpc("report_rework_summary", { p_from: from, p_to: to })
  if (error) throw error
  return data ?? []
}
