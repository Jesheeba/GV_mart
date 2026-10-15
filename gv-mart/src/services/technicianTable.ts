import { supabase } from "@/lib/supabase"
import type { Database, Tables, TablesInsert } from "@/types/database"

// Technician table (migration 20261030100000). Read-only report plus the master-kept holiday list.

export type TechnicianTableRow = Database["public"]["Functions"]["report_technician_table"]["Returns"][number]
export type OrgHolidayRow = Tables<"org_holidays">

export async function getTechnicianTable(from: string, to: string): Promise<TechnicianTableRow[]> {
  const { data, error } = await supabase.rpc("report_technician_table", { p_from: from, p_to: to })
  if (error) throw error
  return data ?? []
}

export async function listHolidays(orgId: string): Promise<OrgHolidayRow[]> {
  const { data, error } = await supabase.from("org_holidays").select("*").eq("org_id", orgId).order("holiday_date", { ascending: false })
  if (error) throw error
  return data
}
export async function createHoliday(row: TablesInsert<"org_holidays">): Promise<OrgHolidayRow> {
  const { data, error } = await supabase.from("org_holidays").insert(row).select().single()
  if (error) throw error
  return data
}
export async function updateHoliday(id: string, patch: { holiday_date?: string; name?: string }): Promise<OrgHolidayRow> {
  const { data, error } = await supabase.from("org_holidays").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}
export async function deleteHoliday(id: string): Promise<void> {
  const { error } = await supabase.from("org_holidays").delete().eq("id", id)
  if (error) throw error
}
