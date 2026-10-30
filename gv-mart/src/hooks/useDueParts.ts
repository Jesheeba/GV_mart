import { useQuery } from "@tanstack/react-query"
import { supabase } from "@/lib/supabase"

/**
 * Product Lifecycle & Automated Service Reminder System — one row per
 * part-replacement schedule the lead's RPC (`get_customer_due_parts`) knows
 * about for a given customer, regardless of which product/installation it's
 * attached to. `status` is computed server-side (today's date vs
 * `nextDueDate`, with some lead window for "due_soon") so this hook never
 * has to duplicate that date math on-device.
 *
 * `get_customer_due_parts` is not yet in the generated `database.ts` RPC
 * types (the lead is building it alongside this) — same minimally-scoped
 * `as never` cast on just this call as `respondToShiftEndPrompt` in
 * services/technician.ts, not the whole client.
 */
export interface CustomerPartSchedule {
  id: string
  installedProductId: string
  label: string
  intervalValue: number
  intervalUnit: "months" | "years"
  lastReplacedDate: string | null
  nextDueDate: string
  status: "pending" | "due_soon" | "due" | "overdue" | "replaced_na"
}

async function fetchDueParts(customerId: string): Promise<CustomerPartSchedule[]> {
  const { data, error } = await supabase.rpc("get_customer_due_parts" as never, { p_customer_id: customerId } as never)
  if (error) throw error
  return (data ?? []) as unknown as CustomerPartSchedule[]
}

/** Query key: ["dueParts", customerId] — same convention as the rest of useTechnician.ts. */
export function useDueParts(customerId: string | undefined) {
  return useQuery({
    queryKey: ["dueParts", customerId],
    queryFn: () => fetchDueParts(customerId!),
    enabled: !!customerId,
    staleTime: 60_000,
  })
}

const NEEDS_ATTENTION_STATUSES = new Set<CustomerPartSchedule["status"]>(["due_soon", "due", "overdue"])

/**
 * Rows a technician actually needs to act on — due_soon/due/overdue.
 * `pending` (not yet due) and `replaced_na` (schedule closed out, nothing
 * further expected) are excluded. Shared by the home-list chip
 * (TechnicianHomePage), the job-detail summary (JobDetailPage), and the
 * on-site warning list (SpareSelectStep) so all three surfaces always agree
 * on exactly which rows count.
 */
export function filterDueOrOverdueParts(rows: CustomerPartSchedule[] | undefined): CustomerPartSchedule[] {
  if (!rows) return []
  return rows.filter((r) => NEEDS_ATTENTION_STATUSES.has(r.status))
}

/** "2 parts due" chip count — see filterDueOrOverdueParts above for which statuses count. */
export function countDueOrOverdueParts(rows: CustomerPartSchedule[] | undefined): number {
  return filterDueOrOverdueParts(rows).length
}
