import { supabase } from "@/lib/supabase"
import { itemNameLookup } from "@/services/sales"
import type { Enums, Tables } from "@/types/database"
import type { FamilyRelation } from "@/lib/validation/customer"

export type CustomerRow = Tables<"customers">
// `relation` (migration 20260703130000_family_member_relation.sql) post-dates
// the last database.ts regen — extended locally, same precedent as
// SettingsWithSla in services/service.ts.
export type MemberRow = Tables<"customer_members"> & { relation: FamilyRelation | null }
export type AddressRow = Tables<"addresses">

export type CustomerListItem = CustomerRow & {
  addresses: Pick<AddressRow, "area" | "pincode" | "address_type" | "is_primary">[]
  member_count: { count: number }[]
}

export type CustomerListFilters = {
  search?: string
  addressType?: Enums<"address_type">
  area?: string
  pincode?: string
  hasAmc?: boolean
  hasWarranty?: boolean
  /** AMC contract within the org's renewal window (amc_contracts.status = 'due_soon'). */
  amcDueSoon?: boolean
  /** Registered 180+ days ago with no invoice or service ticket in the last 180 days. */
  dormant?: boolean
}

const PAGE_SIZE = 20
const DORMANT_WINDOW_DAYS = 180

async function idsMatchingAddressFilter(
  orgId: string,
  { addressType, area, pincode }: CustomerListFilters
): Promise<string[] | null> {
  if (!addressType && !area && !pincode) return null
  let q = supabase.from("addresses").select("customer_id").eq("org_id", orgId)
  if (addressType) q = q.eq("address_type", addressType)
  if (area) q = q.eq("area", area)
  if (pincode) q = q.eq("pincode", pincode)
  const { data, error } = await q
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.customer_id))]
}

/**
 * The quick search box's free text — matches name/mobile on the customer
 * itself OR area/pincode on any of their addresses (unlike the dedicated
 * Area/Pincode filter inputs above, which are exact matches on a single
 * chosen value).
 */
async function idsMatchingSearchTerm(orgId: string, term: string): Promise<string[]> {
  const q = term.trim().replace(/[%,]/g, "")
  if (!q) return []
  const [byNameOrMobile, byAddress] = await Promise.all([
    supabase.from("customers").select("id").eq("org_id", orgId).or(`name.ilike.%${q}%,mobile.ilike.%${q}%`),
    supabase.from("addresses").select("customer_id").eq("org_id", orgId).or(`area.ilike.%${q}%,pincode.ilike.%${q}%`),
  ])
  if (byNameOrMobile.error) throw byNameOrMobile.error
  if (byAddress.error) throw byAddress.error
  return [...new Set([...(byNameOrMobile.data ?? []).map((r) => r.id), ...(byAddress.data ?? []).map((r) => r.customer_id)])]
}

async function idsWithAmc(orgId: string): Promise<string[]> {
  const { data, error } = await supabase.from("amc_contracts").select("customer_id").eq("org_id", orgId)
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.customer_id))]
}

async function idsWithWarranty(orgId: string): Promise<string[]> {
  const { data, error } = await supabase.from("warranties").select("customer_id").eq("org_id", orgId)
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.customer_id))]
}

async function idsByAmcStatus(orgId: string, status: Enums<"amc_status">): Promise<string[]> {
  const { data, error } = await supabase.from("amc_contracts").select("customer_id").eq("org_id", orgId).eq("status", status)
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.customer_id))]
}

/**
 * Registered before the dormancy window with no invoice or service ticket
 * inside it — the only "inactivity" signal the schema actually supports
 * (there's no CRM engagement/last-contacted field to lean on instead).
 */
async function idsDormant(orgId: string, days = DORMANT_WINDOW_DAYS): Promise<string[]> {
  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString()
  const [oldCustomersRes, recentInvoicesRes, recentTicketsRes] = await Promise.all([
    supabase.from("customers").select("id").eq("org_id", orgId).lt("created_at", cutoff),
    supabase.from("invoices").select("customer_id").eq("org_id", orgId).gte("created_at", cutoff),
    supabase.from("service_tickets").select("customer_id").eq("org_id", orgId).gte("created_at", cutoff),
  ])
  if (oldCustomersRes.error) throw oldCustomersRes.error
  if (recentInvoicesRes.error) throw recentInvoicesRes.error
  if (recentTicketsRes.error) throw recentTicketsRes.error
  const recentIds = new Set([
    ...(recentInvoicesRes.data ?? []).map((r) => r.customer_id),
    ...(recentTicketsRes.data ?? []).map((r) => r.customer_id),
  ])
  return (oldCustomersRes.data ?? []).map((r) => r.id).filter((id) => !recentIds.has(id))
}

export async function listCustomers(orgId: string, filters: CustomerListFilters, page: number) {
  const idSets: string[][] = []
  const addrIds = await idsMatchingAddressFilter(orgId, filters)
  if (addrIds) idSets.push(addrIds)
  if (filters.search?.trim()) idSets.push(await idsMatchingSearchTerm(orgId, filters.search))
  if (filters.hasAmc) idSets.push(await idsWithAmc(orgId))
  if (filters.hasWarranty) idSets.push(await idsWithWarranty(orgId))
  if (filters.amcDueSoon) idSets.push(await idsByAmcStatus(orgId, "due_soon"))
  if (filters.dormant) idSets.push(await idsDormant(orgId))

  if (idSets.length > 0) {
    const intersected = idSets.reduce((acc, set) => acc.filter((id) => set.includes(id)))
    if (intersected.length === 0) return { rows: [] as CustomerListItem[], count: 0, pageSize: PAGE_SIZE }
    return queryCustomers(orgId, page, intersected)
  }
  return queryCustomers(orgId, page, null)
}

export type CustomerFilterCounts = { total: number; hasAmc: number; amcDueSoon: number; dormant: number }

/** Real counts for the quick-filter chip row — no fabricated numbers. */
export async function getCustomerFilterCounts(orgId: string): Promise<CustomerFilterCounts> {
  const [totalRes, amcIds, dueSoonIds, dormantIds] = await Promise.all([
    supabase.from("customers").select("id", { count: "exact", head: true }).eq("org_id", orgId),
    idsWithAmc(orgId),
    idsByAmcStatus(orgId, "due_soon"),
    idsDormant(orgId),
  ])
  if (totalRes.error) throw totalRes.error
  return { total: totalRes.count ?? 0, hasAmc: amcIds.length, amcDueSoon: dueSoonIds.length, dormant: dormantIds.length }
}

export type CustomerRowEnrichment = {
  productCount: number
  amcStatus: Enums<"amc_status"> | null
  lastServiceAt: string | null
}

/**
 * Batched per-page enrichment for the list table's Products / AMC / Last
 * service columns — one round-trip per page of rows instead of N+1 queries.
 * "Products owned" mirrors the same three sources service.ts's
 * listOwnedEquipment uses for a single customer (product invoices,
 * warranties, AMC contracts), just batched across a page of customer ids.
 */
export async function getCustomerListEnrichment(
  orgId: string,
  customerIds: string[]
): Promise<Map<string, CustomerRowEnrichment>> {
  const map = new Map<string, CustomerRowEnrichment>()
  if (customerIds.length === 0) return map

  const [invoiceItemsRes, warrantiesRes, amcRes, ticketsRes] = await Promise.all([
    supabase
      .from("invoice_items")
      .select("item_id, invoices!inner(customer_id, org_id, type)")
      .eq("invoices.org_id", orgId)
      .eq("invoices.type", "product")
      .eq("item_type", "product")
      .in("invoices.customer_id", customerIds),
    supabase.from("warranties").select("customer_id, product_id").eq("org_id", orgId).in("customer_id", customerIds),
    supabase.from("amc_contracts").select("customer_id, product_id, status").eq("org_id", orgId).in("customer_id", customerIds),
    supabase
      .from("service_tickets")
      .select("customer_id, updated_at")
      .eq("org_id", orgId)
      .eq("status", "completed")
      .in("customer_id", customerIds),
  ])
  if (invoiceItemsRes.error) throw invoiceItemsRes.error
  if (warrantiesRes.error) throw warrantiesRes.error
  if (amcRes.error) throw amcRes.error
  if (ticketsRes.error) throw ticketsRes.error

  const productSets = new Map<string, Set<string>>()
  const addProduct = (customerId: string, productId: string) => {
    if (!productSets.has(customerId)) productSets.set(customerId, new Set())
    productSets.get(customerId)!.add(productId)
  }
  for (const row of invoiceItemsRes.data ?? []) {
    const customerId = (row as unknown as { invoices: { customer_id: string } }).invoices.customer_id
    addProduct(customerId, row.item_id)
  }
  for (const row of warrantiesRes.data ?? []) addProduct(row.customer_id, row.product_id)
  for (const row of amcRes.data ?? []) addProduct(row.customer_id, row.product_id)

  const amcStatusesByCustomer = new Map<string, Set<Enums<"amc_status">>>()
  for (const row of amcRes.data ?? []) {
    if (!amcStatusesByCustomer.has(row.customer_id)) amcStatusesByCustomer.set(row.customer_id, new Set())
    amcStatusesByCustomer.get(row.customer_id)!.add(row.status)
  }

  const lastServiceByCustomer = new Map<string, string>()
  for (const row of ticketsRes.data ?? []) {
    const existing = lastServiceByCustomer.get(row.customer_id)
    if (!existing || row.updated_at > existing) lastServiceByCustomer.set(row.customer_id, row.updated_at)
  }

  for (const id of customerIds) {
    const statuses = amcStatusesByCustomer.get(id)
    const amcStatus: Enums<"amc_status"> | null = statuses?.has("active")
      ? "active"
      : statuses?.has("due_soon")
        ? "due_soon"
        : statuses?.has("expired")
          ? "expired"
          : null
    map.set(id, {
      productCount: productSets.get(id)?.size ?? 0,
      amcStatus,
      lastServiceAt: lastServiceByCustomer.get(id) ?? null,
    })
  }
  return map
}

async function queryCustomers(orgId: string, page: number, ids: string[] | null) {
  let query = supabase
    .from("customers")
    .select("*, addresses(area,pincode,address_type,is_primary), member_count:customer_members(count)", {
      count: "exact",
    })
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })

  if (ids) query = query.in("id", ids)

  const from = (page - 1) * PAGE_SIZE
  const { data, error, count } = await query.range(from, from + PAGE_SIZE - 1)
  if (error) throw error
  return { rows: (data ?? []) as CustomerListItem[], count: count ?? 0, pageSize: PAGE_SIZE }
}

export async function getCustomer(id: string) {
  const { data, error } = await supabase
    .from("customers")
    .select("*, addresses(*), customer_members(*)")
    .eq("id", id)
    .order("is_primary", { referencedTable: "addresses", ascending: false })
    .order("is_primary", { referencedTable: "customer_members", ascending: false })
    .single()
  if (error) throw error
  // customer_members(*) is typed from the pre-`relation`-column generated
  // schema (see MemberRow comment) — the column IS in the actual row, just
  // not the generated type.
  return { ...data, customer_members: data.customer_members as MemberRow[] }
}

/**
 * Matches on the customer's own name/mobile AND on their address (area,
 * pincode) — a search like "600028" or "Anna Nagar" only exists on the
 * addresses table, so name/mobile alone would always come back empty for
 * those terms.
 */
export async function autocompleteCustomers(orgId: string, term: string) {
  const q = term.trim().replace(/[%,]/g, "")
  if (!q) return []
  const [byNameOrMobile, byAddress] = await Promise.all([
    supabase.from("customers").select("id,name,mobile").eq("org_id", orgId).or(`name.ilike.%${q}%,mobile.ilike.%${q}%`).limit(6),
    supabase
      .from("addresses")
      .select("customers(id,name,mobile)")
      .eq("org_id", orgId)
      .or(`area.ilike.%${q}%,pincode.ilike.%${q}%`)
      .limit(6),
  ])
  if (byNameOrMobile.error) throw byNameOrMobile.error
  if (byAddress.error) throw byAddress.error

  const results = new Map<string, { id: string; name: string; mobile: string }>()
  for (const c of byNameOrMobile.data ?? []) results.set(c.id, c)
  for (const row of (byAddress.data ?? []) as unknown as { customers: { id: string; name: string; mobile: string } | null }[]) {
    if (row.customers && !results.has(row.customers.id)) results.set(row.customers.id, row.customers)
  }
  return [...results.values()].slice(0, 6)
}

export async function checkMobileInUse(orgId: string, mobile: string, excludeCustomerId?: string) {
  const [customersRes, membersRes] = await Promise.all([
    supabase.from("customers").select("id,name,mobile").eq("org_id", orgId).eq("mobile", mobile),
    supabase.from("customer_members").select("id,customer_id,name,mobile").eq("org_id", orgId).eq("mobile", mobile),
  ])
  if (customersRes.error) throw customersRes.error
  if (membersRes.error) throw membersRes.error

  const customerMatch = (customersRes.data ?? []).find((c) => c.id !== excludeCustomerId)
  const memberMatch = (membersRes.data ?? []).find((m) => m.customer_id !== excludeCustomerId)
  if (!customerMatch && !memberMatch) return null

  return {
    customerId: customerMatch?.id ?? memberMatch!.customer_id,
    name: customerMatch?.name ?? memberMatch!.name,
  }
}

export async function searchAreas(orgId: string, term: string) {
  const q = term.trim().replace(/[%,]/g, "")
  if (!q) return []
  const { data, error } = await supabase
    .from("addresses")
    .select("area")
    .eq("org_id", orgId)
    .ilike("area", `%${q}%`)
    .limit(8)
  if (error) throw error
  return [...new Set((data ?? []).map((r) => r.area).filter((a): a is string => !!a))]
}

export async function lookupByPincode(orgId: string, pincode: string) {
  if (!/^\d{6}$/.test(pincode)) return null
  const { data, error } = await supabase
    .from("addresses")
    .select("area,district,state")
    .eq("org_id", orgId)
    .eq("pincode", pincode)
    .limit(1)
  if (error) throw error
  return data?.[0] ?? null
}

export type CreateCustomerInput = {
  orgId: string
  profession?: string
  source?: Enums<"lead_source">
  members: { name: string; mobile: string; isPrimary: boolean; relation?: FamilyRelation }[]
  address: {
    doorNo: string
    flatNo?: string
    streetCross?: string
    area: string
    pincode: string
    landmark?: string
    district?: string
    state?: string
    addressType: Enums<"address_type">
    ownership: Enums<"ownership_type">
    lat?: number
    lng?: number
  }
}

export async function createCustomerWithDetails(input: CreateCustomerInput) {
  const { data, error } = await supabase.rpc("create_customer_with_details", {
    p_org_id: input.orgId,
    // Supabase's generated Args type marks this non-null even though the SQL
    // parameter accepts null (a generator limitation, not a real constraint).
    p_profession: input.profession || "",
    p_source: input.source ?? "other",
    p_members: input.members.map((m) => ({ name: m.name, mobile: m.mobile, is_primary: m.isPrimary, relation: m.relation ?? null })),
    p_address: {
      door_no: input.address.doorNo,
      flat_no: input.address.flatNo ?? "",
      street_cross: input.address.streetCross ?? "",
      area: input.address.area,
      pincode: input.address.pincode,
      landmark: input.address.landmark ?? "",
      district: input.address.district ?? "",
      state: input.address.state ?? "",
      address_type: input.address.addressType,
      ownership: input.address.ownership,
      lat: input.address.lat ?? null,
      lng: input.address.lng ?? null,
    },
  })
  if (error) throw error
  return data
}

export async function updateCustomerProfession(id: string, profession: string) {
  const { data, error } = await supabase.from("customers").update({ profession }).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function addMember(orgId: string, customerId: string, member: { name: string; mobile: string; relation?: FamilyRelation }) {
  const { data, error } = await supabase
    .from("customer_members")
    // `relation` isn't in the generated Insert type yet (see MemberRow comment) — same
    // locally-extended-row precedent, cast narrows back to `never` only on this one call.
    .insert({
      org_id: orgId,
      customer_id: customerId,
      name: member.name,
      mobile: member.mobile,
      is_primary: false,
      relation: member.relation ?? null,
    } as never)
    .select()
    .single()
  if (error) throw error
  return data as unknown as MemberRow
}

export async function removeMember(memberId: string) {
  const { error } = await supabase.from("customer_members").delete().eq("id", memberId)
  if (error) throw error
}

export async function setPrimaryMember(customerId: string, memberId: string) {
  const { error } = await supabase.rpc("set_primary_member", { p_customer_id: customerId, p_member_id: memberId })
  if (error) throw error
}

export async function moveMemberOut(orgId: string, member: MemberRow) {
  const { data: newCustomer, error: createError } = await supabase
    .from("customers")
    .insert({ org_id: orgId, name: member.name, mobile: member.mobile })
    .select()
    .single()
  if (createError) throw createError
  const { error: deleteError } = await supabase.from("customer_members").delete().eq("id", member.id)
  if (deleteError) throw deleteError
  return newCustomer
}

export async function upsertPrimaryAddress(
  orgId: string,
  customerId: string,
  existingAddressId: string | null,
  patch: {
    doorNo: string
    flatNo?: string
    streetCross?: string
    area: string
    pincode: string
    landmark?: string
    district?: string
    state?: string
    addressType: Enums<"address_type">
    ownership: Enums<"ownership_type">
    lat?: number
    lng?: number
  }
) {
  const row = {
    door_no: patch.doorNo,
    flat_no: patch.flatNo || null,
    street_cross: patch.streetCross || null,
    area: patch.area,
    pincode: patch.pincode,
    landmark: patch.landmark || null,
    district: patch.district || null,
    state: patch.state || null,
    address_type: patch.addressType,
    ownership: patch.ownership,
    lat: patch.lat ?? null,
    lng: patch.lng ?? null,
  }
  if (existingAddressId) {
    const { data, error } = await supabase.from("addresses").update(row).eq("id", existingAddressId).select().single()
    if (error) throw error
    return data
  }
  const { data, error } = await supabase
    .from("addresses")
    .insert({ org_id: orgId, customer_id: customerId, ...row, is_primary: true })
    .select()
    .single()
  if (error) throw error
  return data
}

// ── Customer detail page: Products / Service history / Invoices / lifetime ──

export type CustomerProductRow = {
  productId: string
  productName: string
  brandName: string | null
  modelName: string | null
  category: Enums<"brand_category"> | null
  boughtAt: string | null
  serialNo: string | null
  warrantyExpiry: string | null
  amcStatus: Enums<"amc_status"> | null
  amcPlanName: string | null
  amcExpiry: string | null
}

/**
 * A customer's owned equipment, enriched with purchase date, serial number
 * and coverage (warranty or AMC) — the same three sources
 * service.ts#listOwnedEquipment unions for a single customer, extended here
 * with the extra fields the detail page's Products tab needs to render.
 */
export async function getCustomerProducts(orgId: string, customerId: string): Promise<CustomerProductRow[]> {
  const [invoiceItemsRes, warrantiesRes, amcRes] = await Promise.all([
    supabase
      .from("invoice_items")
      .select("item_id, invoices!inner(customer_id, org_id, type, created_at)")
      .eq("invoices.customer_id", customerId)
      .eq("invoices.org_id", orgId)
      .eq("invoices.type", "product")
      .eq("item_type", "product"),
    supabase.from("warranties").select("*").eq("org_id", orgId).eq("customer_id", customerId),
    supabase.from("amc_contracts").select("*, amc_plans(name,years)").eq("org_id", orgId).eq("customer_id", customerId),
  ])
  if (invoiceItemsRes.error) throw invoiceItemsRes.error
  if (warrantiesRes.error) throw warrantiesRes.error
  if (amcRes.error) throw amcRes.error

  const invoiceItems = (invoiceItemsRes.data ?? []) as unknown as { item_id: string; invoices: { created_at: string } }[]
  const warranties = warrantiesRes.data ?? []
  const amcContracts = (amcRes.data ?? []) as unknown as (Tables<"amc_contracts"> & { amc_plans: { name: string; years: number } | null })[]

  const productIds = new Set<string>([
    ...invoiceItems.map((i) => i.item_id),
    ...warranties.map((w) => w.product_id),
    ...amcContracts.map((a) => a.product_id),
  ])
  if (productIds.size === 0) return []

  const { data: products, error: productsError } = await supabase
    .from("products")
    .select("id, name, category, brands(name), models(name)")
    .in("id", [...productIds])
  if (productsError) throw productsError

  return [...productIds].map((productId) => {
    const product = (products ?? []).find((p) => p.id === productId)
    const invoiceItem = invoiceItems.find((i) => i.item_id === productId)
    const warranty = warranties.find((w) => w.product_id === productId)
    const amcContract = amcContracts.find((a) => a.product_id === productId)
    return {
      productId,
      productName: product?.name ?? "—",
      brandName: product?.brands?.name ?? null,
      modelName: product?.models?.name ?? null,
      category: product?.category ?? null,
      boughtAt: invoiceItem?.invoices.created_at ?? warranty?.start_date ?? amcContract?.start_date ?? null,
      serialNo: warranty?.serial_no ?? null,
      warrantyExpiry: warranty?.expiry_date ?? null,
      amcStatus: amcContract?.status ?? null,
      amcPlanName: amcContract?.amc_plans?.name ?? null,
      amcExpiry: amcContract?.expiry_date ?? null,
    }
  })
}

export type CustomerServiceHistoryRow = {
  ticketId: string
  title: string
  type: Enums<"ticket_type"> | null
  status: Enums<"ticket_status">
  technicianName: string | null
  amount: number
  date: string
}

export async function getCustomerServiceHistory(orgId: string, customerId: string, limit = 12): Promise<CustomerServiceHistoryRow[]> {
  const { data, error } = await supabase
    .from("service_tickets")
    .select(
      "id, name_of_complaint, type, status, created_at, updated_at, appointments(technicians(profiles(full_name))), invoices(total)"
    )
    .eq("org_id", orgId)
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
    .limit(limit)
  if (error) throw error

  return (data ?? []).map((row) => {
    const r = row as unknown as {
      id: string
      name_of_complaint: string | null
      type: Enums<"ticket_type"> | null
      status: Enums<"ticket_status">
      created_at: string
      updated_at: string
      appointments: { technicians: { profiles: { full_name: string } | null } | null }[]
      invoices: { total: number } | null
    }
    const technicianName = r.appointments.find((a) => a.technicians?.profiles?.full_name)?.technicians?.profiles?.full_name ?? null
    return {
      ticketId: r.id,
      title: r.name_of_complaint ?? "—",
      type: r.type,
      status: r.status,
      technicianName,
      amount: r.invoices?.total ? Number(r.invoices.total) : 0,
      date: r.status === "completed" ? r.updated_at : r.created_at,
    }
  })
}

export type CustomerInvoiceRow = {
  id: string
  itemsLabel: string
  total: number
  createdAt: string
  type: Enums<"invoice_type">
}

export async function getCustomerInvoices(orgId: string, customerId: string, limit = 12): Promise<CustomerInvoiceRow[]> {
  const { data, error } = await supabase
    .from("invoices")
    .select("id, type, total, created_at, invoice_items(item_type, item_id)")
    .eq("org_id", orgId)
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
    .limit(limit)
  if (error) throw error
  const rows = data ?? []
  const names = await itemNameLookup(
    orgId,
    rows.flatMap((r) => r.invoice_items)
  )
  return rows.map((r) => ({
    id: r.id,
    itemsLabel: r.invoice_items.map((i) => names.get(i.item_id) ?? "—").join(" + ") || "—",
    total: Number(r.total),
    createdAt: r.created_at,
    type: r.type,
  }))
}

export type CustomerNextAmcAction = { productName: string; planName: string; expiryDate: string; daysUntil: number }
export type CustomerLifetimeSummary = { total: number; invoiceCount: number; nextAmcAction: CustomerNextAmcAction | null }

/**
 * Lifetime value = real sum of the customer's own invoices (no fabricated
 * "customer tier" or points system exists in the schema). "Next best
 * action" is likewise derived from a real signal — the soonest AMC contract
 * that's entered the org's renewal window — rather than an AI suggestion.
 */
export async function getCustomerLifetimeSummary(orgId: string, customerId: string): Promise<CustomerLifetimeSummary> {
  const [invoicesRes, amcRes] = await Promise.all([
    supabase.from("invoices").select("total").eq("org_id", orgId).eq("customer_id", customerId),
    supabase
      .from("amc_contracts")
      .select("expiry_date, products(name), amc_plans(name)")
      .eq("org_id", orgId)
      .eq("customer_id", customerId)
      .eq("status", "due_soon")
      .order("expiry_date", { ascending: true })
      .limit(1),
  ])
  if (invoicesRes.error) throw invoicesRes.error
  if (amcRes.error) throw amcRes.error

  const invoices = invoicesRes.data ?? []
  const total = invoices.reduce((sum, r) => sum + Number(r.total), 0)

  const nextContract = amcRes.data?.[0] as unknown as
    | { expiry_date: string; products: { name: string } | null; amc_plans: { name: string } | null }
    | undefined
  const nextAmcAction: CustomerNextAmcAction | null = nextContract
    ? {
        productName: nextContract.products?.name ?? "—",
        planName: nextContract.amc_plans?.name ?? "—",
        expiryDate: nextContract.expiry_date,
        daysUntil: Math.max(0, Math.ceil((new Date(nextContract.expiry_date).getTime() - Date.now()) / 86_400_000)),
      }
    : null

  return { total, invoiceCount: invoices.length, nextAmcAction }
}
