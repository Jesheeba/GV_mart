import { supabase } from "@/lib/supabase"

// Item 1 (2026-09-21) — technician KYC documents (Aadhar card / Driving
// Licence), stored as a photo of the physical card rather than a typed
// number. Same private-bucket + storage_path + signed-URL-on-demand shape as
// ticketPhotos.ts/paymentProofs.ts: technicians.aadhar_document_path /
// driving_licence_document_path hold the bucket-relative path only and are
// never rendered inline — an admin has to explicitly request a signed URL to
// view one, so the document stays masked until someone actually needs to see
// it. Unlike those two files, the upload here is NOT passed through
// resizeImage first — that helper caps images at 800px, which would make a
// photographed ID card's printed text illegible. See
// 20260921100000_technician_documents.sql for the bucket/columns/RLS.

export async function uploadTechnicianDocument(orgId: string, file: File): Promise<string> {
  const ext = file.type === "image/png" ? "png" : file.type === "image/webp" ? "webp" : "jpg"
  const path = `${orgId}/${crypto.randomUUID()}.${ext}`
  const { error } = await supabase.storage.from("technician-documents").upload(path, file, { contentType: file.type })
  if (error) throw error
  return path
}

export async function technicianDocumentSignedUrl(storagePath: string): Promise<string> {
  const { data, error } = await supabase.storage.from("technician-documents").createSignedUrl(storagePath, 3600)
  if (error) throw error
  return data.signedUrl
}
