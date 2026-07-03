import { supabase } from "@/lib/supabase"
import type { Enums, Tables } from "@/types/database"

export type CustomerRow = Tables<"customers">
export type MemberRow = Tables<"customer_members">
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
}

const PAGE_SIZE = 20

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

export async function listCustomers(orgId: string, filters: CustomerListFilters, page: number) {
  const idSets: string[][] = []
  const addrIds = await idsMatchingAddressFilter(orgId, filters)
  if (addrIds) idSets.push(addrIds)
  if (filters.hasAmc) idSets.push(await idsWithAmc(orgId))
  if (filters.hasWarranty) idSets.push(await idsWithWarranty(orgId))

  if (idSets.length > 0) {
    const intersected = idSets.reduce((acc, set) => acc.filter((id) => set.includes(id)))
    if (intersected.length === 0) return { rows: [] as CustomerListItem[], count: 0, pageSize: PAGE_SIZE }
    return queryCustomers(orgId, filters, page, intersected)
  }
  return queryCustomers(orgId, filters, page, null)
}

async function queryCustomers(orgId: string, filters: CustomerListFilters, page: number, ids: string[] | null) {
  let query = supabase
    .from("customers")
    .select("*, addresses(area,pincode,address_type,is_primary), member_count:customer_members(count)", {
      count: "exact",
    })
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })

  if (filters.search?.trim()) {
    const term = filters.search.trim().replace(/[%,]/g, "")
    query = query.or(`name.ilike.%${term}%,mobile.ilike.%${term}%`)
  }
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
  return data
}

export async function autocompleteCustomers(orgId: string, term: string) {
  const q = term.trim().replace(/[%,]/g, "")
  if (!q) return []
  const { data, error } = await supabase
    .from("customers")
    .select("id,name,mobile")
    .eq("org_id", orgId)
    .or(`name.ilike.%${q}%,mobile.ilike.%${q}%`)
    .limit(6)
  if (error) throw error
  return data ?? []
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
  members: { name: string; mobile: string; isPrimary: boolean }[]
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
  }
}

export async function createCustomerWithDetails(input: CreateCustomerInput) {
  const { data, error } = await supabase.rpc("create_customer_with_details", {
    p_org_id: input.orgId,
    // Supabase's generated Args type marks this non-null even though the SQL
    // parameter accepts null (a generator limitation, not a real constraint).
    p_profession: input.profession || "",
    p_source: input.source ?? "other",
    p_members: input.members.map((m) => ({ name: m.name, mobile: m.mobile, is_primary: m.isPrimary })),
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

export async function addMember(orgId: string, customerId: string, member: { name: string; mobile: string }) {
  const { data, error } = await supabase
    .from("customer_members")
    .insert({ org_id: orgId, customer_id: customerId, name: member.name, mobile: member.mobile, is_primary: false })
    .select()
    .single()
  if (error) throw error
  return data
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
