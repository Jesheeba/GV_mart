import { useQuery } from "@tanstack/react-query"
import { supabase } from "@/lib/supabase"
import type { CustomerPartSchedule } from "@/hooks/useDueParts"

export type { CustomerPartSchedule }

/**
 * Product Lifecycle & Automated Service Reminder System — Drop 2, W3
 * (customer-facing). Read-only, in-app surfacing of the signed-in
 * customer's own installed products: part-due status and replacement
 * history. No push notifications exist in this app, so these are plain
 * TanStack Query hooks read on page load/refresh, same as every other
 * customer-app screen (see useCustomerApp.ts).
 */
export interface CustomerInstalledProduct {
  id: string
  productId: string
  installationDate: string
  lifetimeExpiryDate: string | null
  status: "active" | "expired" | "removed"
}

export interface ReplacementHistoryEntry {
  id: string
  label: string
  replacedDate: string
  previousDueDate: string
  nextDueDate: string
  productId: string
  installedProductId: string
}

async function fetchInstalledProducts(customerId: string): Promise<CustomerInstalledProduct[]> {
  const { data, error } = await supabase.rpc("get_customer_installed_products" as never, { p_customer_id: customerId } as never)
  if (error) throw error
  return (data ?? []) as unknown as CustomerInstalledProduct[]
}

export function useCustomerInstalledProducts(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerInstalledProducts", customerId],
    queryFn: () => fetchInstalledProducts(customerId!),
    enabled: !!customerId,
    staleTime: 60_000,
  })
}

// Same RPC + shape the technician side already calls in useDueParts.ts
// (get_customer_due_parts) — reused here with the customer's own id.
async function fetchCustomerDueParts(customerId: string): Promise<CustomerPartSchedule[]> {
  const { data, error } = await supabase.rpc("get_customer_due_parts" as never, { p_customer_id: customerId } as never)
  if (error) throw error
  return (data ?? []) as unknown as CustomerPartSchedule[]
}

export function useCustomerDueParts(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerDueParts", customerId],
    queryFn: () => fetchCustomerDueParts(customerId!),
    enabled: !!customerId,
    staleTime: 60_000,
  })
}

async function fetchReplacementHistory(customerId: string): Promise<ReplacementHistoryEntry[]> {
  const { data, error } = await supabase.rpc("get_customer_replacement_history" as never, { p_customer_id: customerId } as never)
  if (error) throw error
  return (data ?? []) as unknown as ReplacementHistoryEntry[]
}

export function useCustomerReplacementHistory(customerId: string | undefined) {
  return useQuery({
    queryKey: ["customerReplacementHistory", customerId],
    queryFn: () => fetchReplacementHistory(customerId!),
    enabled: !!customerId,
    staleTime: 60_000,
  })
}

// ── Pure helpers (tested in useCustomerLifecycle.test.ts) ──────────────────

const ALERT_STATUSES = new Set<CustomerPartSchedule["status"]>(["due_soon", "due", "overdue"])

/**
 * The single most urgent due/overdue part across all of the customer's
 * installed products — used by CustomerHomePage's lifecycle banner. `null`
 * when nothing needs attention (pending/replaced_na rows don't count).
 */
export function pickSoonestDuePart(rows: CustomerPartSchedule[] | undefined): CustomerPartSchedule | null {
  const candidates = (rows ?? []).filter((r) => ALERT_STATUSES.has(r.status))
  if (candidates.length === 0) return null
  return candidates.slice().sort((a, b) => (a.nextDueDate < b.nextDueDate ? -1 : 1))[0]
}

/** True once `expiryDate` is within `withinDays` of `todayIso`, or already past it. */
export function isLifetimeExpiryNear(expiryDate: string | null | undefined, todayIso: string, withinDays = 90): boolean {
  if (!expiryDate) return false
  const diffDays = Math.ceil((new Date(expiryDate).getTime() - new Date(todayIso).getTime()) / (1000 * 60 * 60 * 24))
  return diffDays <= withinDays
}

/**
 * Due/overdue-or-soon part rows for one catalog product, grouped via the
 * installed-product record that links a `get_customer_due_parts` row
 * (keyed by installedProductId) back to its catalog product id — the same
 * id CustomerProductsPage/OwnedProductStatusCard key their cards by.
 */
export function groupDuePartsByProductId(
  dueParts: CustomerPartSchedule[] | undefined,
  installedProducts: CustomerInstalledProduct[] | undefined
): Map<string, CustomerPartSchedule[]> {
  const installedById = new Map((installedProducts ?? []).map((p) => [p.id, p]))
  const byProduct = new Map<string, CustomerPartSchedule[]>()
  for (const row of dueParts ?? []) {
    if (!ALERT_STATUSES.has(row.status)) continue
    const productId = installedById.get(row.installedProductId)?.productId
    if (!productId) continue
    const existing = byProduct.get(productId)
    if (existing) existing.push(row)
    else byProduct.set(productId, [row])
  }
  return byProduct
}

/**
 * The soonest lifetime-expiry date among this product's active installed
 * units, or `null` if none/not active. A customer can own more than one
 * unit of the same catalog product (rare, but possible after a swap), so
 * this picks the most urgent one rather than an arbitrary first match.
 */
export function getLifetimeExpiryForProduct(
  installedProducts: CustomerInstalledProduct[] | undefined,
  productId: string
): string | null {
  const dates = (installedProducts ?? [])
    .filter((p) => p.productId === productId && p.status === "active" && p.lifetimeExpiryDate)
    .map((p) => p.lifetimeExpiryDate as string)
    .sort()
  return dates[0] ?? null
}
