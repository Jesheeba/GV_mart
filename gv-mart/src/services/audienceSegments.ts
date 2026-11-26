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

/** Text-field operators the UI offers; boolean fields have no operator control (yes/no is unambiguous). */
export const SEGMENT_TEXT_OPERATORS = [
  { operator: "=", label: "equals" },
  { operator: "contains", label: "contains" },
] as const

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

/** Rule-builder draft: every part (and/or, field, operator, yes/no) starts "Not set" ("") — owner rule 2026-11-26. */
export type SegmentDraftLeaf = { field: string; operator: string; value: string | boolean }
export type SegmentDraftTree = { op: SegmentConditionTree["op"] | ""; conditions: SegmentDraftLeaf[] }

export const emptySegmentLeaf = (): SegmentDraftLeaf => ({ field: "", operator: "", value: "" })
export const emptySegmentDraft = (): SegmentDraftTree => ({ op: "", conditions: [emptySegmentLeaf()] })

/** The stored/RPC tree (same jsonb shape as before), or null while any part is still "Not set" or a text value is
 * blank — an incomplete rule is never counted, previewed or saved. Boolean leaves keep operator "=". */
export function completeSegmentTree(draft: SegmentDraftTree): SegmentConditionTree | null {
  if (!draft.op || draft.conditions.length === 0) return null
  const conditions: SegmentConditionLeaf[] = []
  for (const leaf of draft.conditions) {
    const def = SEGMENT_FIELDS.find((f) => f.field === leaf.field)
    if (!def) return null
    if (def.kind === "boolean") {
      if (typeof leaf.value !== "boolean") return null
      conditions.push({ field: leaf.field, operator: "=", value: leaf.value })
    } else {
      if (!SEGMENT_TEXT_OPERATORS.some((o) => o.operator === leaf.operator)) return null
      if (typeof leaf.value !== "string" || !leaf.value.trim()) return null
      conditions.push({ field: leaf.field, operator: leaf.operator, value: leaf.value })
    }
  }
  return { op: draft.op, conditions }
}

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

/** Real existing values for a field (e.g. actual cities/brands already in the data), so the value
 * box can suggest instead of the admin guessing exact spelling/case blind. */
export async function segmentFieldValues(orgId: string, field: string, query = ""): Promise<string[]> {
  const { data, error } = await supabase.rpc("audience_segment_field_values", { p_org_id: orgId, p_field: field, p_query: query })
  if (error) throw error
  return (data ?? []).map((r: { value: string }) => r.value).filter((v: string | null): v is string => !!v)
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
  const { data, error } = await supabase
    .from("whatsapp_wasi_templates")
    .select("wasi_name")
    .eq("status", "approved")
    .ilike("wasi_name", "gvm_%")
    .order("wasi_name")
  if (error) throw error
  return (data ?? []).map((r) => r.wasi_name)
}
