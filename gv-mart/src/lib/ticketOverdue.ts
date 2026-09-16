import type { Enums } from "@/types/database"

/**
 * Shared "past its SLA and still open" rule. Previously copy-pasted three
 * times (admin list, admin kanban, technician job list) — kept here as a
 * standalone pure function, not in services/service.ts, so technician.ts
 * doesn't have to import the admin-side service module just for this.
 */
export function isTicketOverdue(ticket: { sla_due_at: string | null; status: Enums<"ticket_status"> }, now: number): boolean {
  return !!ticket.sla_due_at && ticket.status !== "completed" && ticket.status !== "cancelled" && new Date(ticket.sla_due_at).getTime() <= now
}
