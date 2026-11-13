// Segment Builder (advanced/secondary automation) — see build-docs/features/segment-builder.md.
// Master-only (RLS: is_master()). Condition-tree shape: { op: 'and'|'or', conditions: [...] } where
// a leaf is { field, operator, value }. Evaluated entirely in Postgres (_segment_tree_match) —
// this file never evaluates the tree client-side, only builds/stores it and calls the RPCs.
import { supabase } from "@/lib/supabase"
import type { Tables } from "@/types/database"

export type AudienceSegmentRow = Tables<"audience_segments">
export type AudienceSegmentRunRow = Tables<"audience_segment_runs">

export type SegmentConditionLeaf = { field: string; operator: string; value: string | boolean | string[] }
export type SegmentConditionTree = { op: "and" | "or"; conditions: (SegmentConditionLeaf | SegmentConditionTree)[] }

export const SEGMENT_FIELDS = [
  { field: "customer.city", label: "City", kind: "text" },
  { field: "customer.tag", label: "Customer tag", kind: "text" },
  { field: "lead.status", label: "Lead status", kind: "text" },
  { field: "product.brand", label: "Product brand", kind: "text" },
  { field: "product.category", label: "Product category", kind: "text" },
  { field: "product.name", label: "Product name", kind: "text" },
  { field: "amc.active", label: "Has active AMC", kind: "boolean" },
  { field: "warranty.active", label: "Has active warranty", kind: "boolean" },
] as const

export async function listAudienceSegments(orgId: string): Promise<AudienceSegmentRow[]> {
  const { data, error } = await supabase.from("audience_segments").select("*").eq("org_id", orgId).order("created_at", { ascending: false })
  if (error) throw error
  return data ?? []
}

export async function saveAudienceSegment(input: { orgId: string; name: string; conditionTree: SegmentConditionTree; wasiTemplateName: string | null; dedupeDays?: number }) {
  const { data, error } = await supabase
    .from("audience_segments")
    .upsert(
      { org_id: input.orgId, name: input.name, condition_tree: input.conditionTree, wasi_template_name: input.wasiTemplateName, dedupe_days: input.dedupeDays ?? 7 },
      { onConflict: "org_id,name" }
    )
    .select()
    .single()
  if (error) throw error
  return data
}

export async function deleteAudienceSegment(id: string) {
  const { error } = await supabase.from("audience_segments").delete().eq("id", id)
  if (error) throw error
}

export async function matchCount(orgId: string, conditionTree: SegmentConditionTree): Promise<number> {
  const { data, error } = await supabase.rpc("audience_segment_match_count", { p_org_id: orgId, p_condition_tree: conditionTree })
  if (error) throw error
  return data ?? 0
}

export async function matchPreview(orgId: string, conditionTree: SegmentConditionTree, limit = 5) {
  const { data, error } = await supabase.rpc("audience_segment_match_preview", { p_org_id: orgId, p_condition_tree: conditionTree, p_limit: limit })
  if (error) throw error
  return data ?? []
}

export async function sendSegmentNow(segmentId: string): Promise<string> {
  const { data, error } = await supabase.rpc("audience_segment_send_now", { p_segment_id: segmentId })
  if (error) throw error
  return data
}

export async function setSegmentStanding(segmentId: string, isStanding: boolean, wasiTemplateName: string | null) {
  const { error } = await supabase.rpc("audience_segment_set_standing", { p_segment_id: segmentId, p_is_standing: isStanding, p_wasi_template_name: wasiTemplateName })
  if (error) throw error
}

export async function listSegmentRuns(segmentId: string): Promise<AudienceSegmentRunRow[]> {
  const { data, error } = await supabase.from("audience_segment_runs").select("*").eq("segment_id", segmentId).order("fired_at", { ascending: false }).limit(20)
  if (error) throw error
  return data ?? []
}

/** Approved gvm_* templates available to pick from — the same source the Chunk A/B wiring reads. */
export async function listApprovedTemplateNames(): Promise<string[]> {
  const { data, error } = await supabase.from("whatsapp_wasi_templates").select("wasi_name").eq("status", "approved").order("wasi_name")
  if (error) throw error
  return (data ?? []).map((r) => r.wasi_name)
}
