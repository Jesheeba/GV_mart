import { supabase } from "@/lib/supabase"

// Round-robin lead assignment (migration 20261010100000_lead_round_robin.sql).
// The switch lives on settings (master-only write by RLS); "waiting" leads are the ones saved
// unassigned while auto-assign was on and nobody was eligible.

export type LeadAssignState = {
  enabled: boolean
  /** Active sales persons currently set to receive new leads. */
  receivers: number
  /** Leads flagged auto_assign_pending (waiting for someone to become eligible). */
  waiting: number
}

export async function getLeadAssignState(orgId: string): Promise<LeadAssignState> {
  const [settingsRes, receiversRes, waitingRes] = await Promise.all([
    supabase.from("settings").select("auto_assign_leads").eq("org_id", orgId).maybeSingle(),
    supabase
      .from("profiles")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .eq("role", "sales_admin")
      .eq("is_active", true)
      .eq("receives_new_leads", true),
    supabase.from("leads").select("id", { count: "exact", head: true }).eq("org_id", orgId).eq("auto_assign_pending", true),
  ])
  if (settingsRes.error) throw settingsRes.error
  if (receiversRes.error) throw receiversRes.error
  if (waitingRes.error) throw waitingRes.error
  return {
    enabled: settingsRes.data?.auto_assign_leads ?? false,
    receivers: receiversRes.count ?? 0,
    waiting: waitingRes.count ?? 0,
  }
}

export async function setAutoAssignLeads(orgId: string, enabled: boolean) {
  const { error } = await supabase.from("settings").update({ auto_assign_leads: enabled }).eq("org_id", orgId)
  if (error) throw error
}

/** Master-only (profiles guard trigger): pause / resume a sales person for new leads. */
export async function setReceivesNewLeads(profileId: string, receives: boolean) {
  const { error } = await supabase.from("profiles").update({ receives_new_leads: receives }).eq("id", profileId)
  if (error) throw error
}
