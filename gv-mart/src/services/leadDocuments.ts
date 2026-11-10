import { supabase } from "@/lib/supabase"

// Lead Dashboard Enhancement, feature 4 — optional report/document upload on
// a lead. Same private-bucket + storage_path + signed-URL-on-demand shape as
// paymentProofs.ts/technicianDocuments.ts, but a generic file (pdf/doc/xls/
// image), not image-only, so no resize step. The row write goes through
// record_lead_document (SECURITY DEFINER), not a direct table update — see
// 20261110100000_lead_detail_fields.sql for the bucket/column/RLS/allowed
// MIME types, which this list must stay in sync with.

export const LEAD_DOCUMENT_ALLOWED_TYPES = [
  "application/pdf",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "image/jpeg",
  "image/png",
] as const

export const LEAD_DOCUMENT_MAX_BYTES = 10 * 1024 * 1024 // matches the bucket's file_size_limit

const EXT_BY_TYPE: Record<string, string> = {
  "application/pdf": "pdf",
  "application/msword": "doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
  "application/vnd.ms-excel": "xls",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
  "image/jpeg": "jpg",
  "image/png": "png",
}

export function validateLeadDocument(file: File): string | null {
  if (!LEAD_DOCUMENT_ALLOWED_TYPES.includes(file.type as (typeof LEAD_DOCUMENT_ALLOWED_TYPES)[number])) return "unsupportedType"
  if (file.size > LEAD_DOCUMENT_MAX_BYTES) return "tooLarge"
  return null
}

export async function uploadLeadDocument(orgId: string, leadId: string, file: File) {
  const invalid = validateLeadDocument(file)
  if (invalid) throw new Error(invalid)

  const ext = EXT_BY_TYPE[file.type] ?? "bin"
  const path = `${orgId}/${leadId}/${crypto.randomUUID()}.${ext}`
  const { error: uploadError } = await supabase.storage.from("lead-reports").upload(path, file, { contentType: file.type })
  if (uploadError) throw uploadError

  const { data, error } = await supabase.rpc("record_lead_document", { p_org_id: orgId, p_lead_id: leadId, p_storage_path: path })
  if (error) throw error
  return data as unknown as { ok: boolean; lead_id: string }
}

export async function leadDocumentSignedUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from("lead-reports").createSignedUrl(storagePath, 3600)
  if (error) throw error
  return data.signedUrl
}
