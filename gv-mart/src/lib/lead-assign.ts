import type { LeadAssignee } from "@/services/leadFollowups"
import type { UserRole } from "@/lib/roles"

export type AssignableLead = { id: string; name: string; assignedTo: string | null }
export type AssignAction = "assign" | "reassign" | "pickup" | "handover"

/**
 * What the signed-in person may do with this lead (mirrors assign_lead on the server):
 *   master — assign / reassign anyone; sales_admin — pick up an unassigned lead, or hand their own to a colleague.
 * A lead whose assignee is no longer an active master/sales_admin counts as unassigned.
 */
export function assignActionFor(role: UserRole | undefined, myId: string | undefined, assignedTo: string | null, assignees: LeadAssignee[]): AssignAction | null {
  const effective = assignedTo && assignees.some((a) => a.id === assignedTo) ? assignedTo : null
  if (role === "master") return effective ? "reassign" : "assign"
  if (role === "sales_admin") {
    if (!effective) return "pickup"
    if (effective === myId) return "handover"
  }
  return null
}

