import { useQuery } from "@tanstack/react-query"
import { supabase } from "@/lib/supabase"

/**
 * Product Lifecycle widget (W4 drop).
 *
 * `customer_part_schedules` / `customer_installed_products` are new tables the
 * lead is adding alongside the `report_kpi_tiles.service.lifecycle` extension
 * this widget's counts come from — they are not yet in the generated
 * `src/types/database.ts`, so the two `.from(...)` calls below are cast past
 * the Supabase client's strict table-name typing. Once the lead regenerates
 * `database.ts` after the migration lands, these casts can be dropped and the
 * row shapes below should be checked against the real generated columns.
 */

export type LifecycleStatusFilter = "due_soon" | "due" | "overdue"

export type LifecyclePartScheduleRow = {
  id: string
  label: string
  next_due_date: string | null
  status: string
  installed_product_id: string
  customer_installed_products: {
    id: string
    customer_id: string
    product_id: string
    lifetime_expiry_date: string | null
    customers: { id: string; name: string | null } | null
    products: { id: string; name: string | null } | null
  } | null
}

export type LifecycleExpiringProductRow = {
  id: string
  customer_id: string
  product_id: string
  lifetime_expiry_date: string | null
  customers: { id: string; name: string | null } | null
  products: { id: string; name: string | null } | null
}

const PART_SCHEDULE_SELECT =
  "id, label, next_due_date, status, installed_product_id, customer_installed_products(id, customer_id, product_id, lifetime_expiry_date, customers(id, name), products(id, name))"

const INSTALLED_PRODUCT_SELECT = "id, customer_id, product_id, lifetime_expiry_date, customers(id, name), products(id, name)"

async function fetchPartSchedules(orgId: string, status: LifecycleStatusFilter): Promise<LifecyclePartScheduleRow[]> {
  const { data, error } = await (supabase.from as (table: string) => any)("customer_part_schedules")
    .select(PART_SCHEDULE_SELECT)
    .eq("org_id", orgId)
    .eq("status", status)
    .order("next_due_date", { ascending: true })
  if (error) throw error
  return (data ?? []) as LifecyclePartScheduleRow[]
}

async function fetchLifetimeExpiring(orgId: string, withinDays: number): Promise<LifecycleExpiringProductRow[]> {
  const today = new Date()
  const until = new Date(today.getTime() + withinDays * 86_400_000)
  const todayIso = today.toISOString().slice(0, 10)
  const untilIso = until.toISOString().slice(0, 10)
  const { data, error } = await (supabase.from as (table: string) => any)("customer_installed_products")
    .select(INSTALLED_PRODUCT_SELECT)
    .eq("org_id", orgId)
    .not("lifetime_expiry_date", "is", null)
    .gte("lifetime_expiry_date", todayIso)
    .lte("lifetime_expiry_date", untilIso)
    .order("lifetime_expiry_date", { ascending: true })
  if (error) throw error
  return (data ?? []) as LifecycleExpiringProductRow[]
}

/**
 * Backs `LifecycleOverviewPage`. `status` selects which of the widget's 4
 * counts this list is for: the three `customer_part_schedules` statuses, or
 * `"lifetime_expiring_90d"` for the separate "nearing lifetime expiry" list
 * (queried straight off `customer_installed_products`, no schedule join).
 */
export function useLifecycleOverview(orgId: string | undefined, status: LifecycleStatusFilter | "lifetime_expiring_90d") {
  return useQuery({
    queryKey: ["lifecycle_overview", orgId, status],
    queryFn: (): Promise<(LifecyclePartScheduleRow | LifecycleExpiringProductRow)[]> =>
      status === "lifetime_expiring_90d" ? fetchLifetimeExpiring(orgId!, 90) : fetchPartSchedules(orgId!, status),
    enabled: !!orgId,
  })
}
