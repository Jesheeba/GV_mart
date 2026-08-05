import { supabase } from "@/lib/supabase"
import { fileToDataUrl, resizeImage } from "@/lib/offline/capture"

// Gate-assignment-on-product (2026-08-04): optional customer-attached
// photo(s) on a service ticket, offered when the customer picks "I don't
// know the product" during booking — helps whoever fills in the product
// later see what the customer actually has. Same resize-then-upload-then-
// insert-row shape as productMedia.ts#uploadProductImage, but the bucket is
// private (this is customer evidence tied to one ticket, not marketing
// collateral) so display goes through a signed URL, not a public one. See
// 20260804170000_gate_assignment_on_product.sql for the bucket/table/RLS.

async function resizeImageFile(file: File): Promise<Blob> {
  const dataUrl = await fileToDataUrl(file)
  const resizedDataUrl = await resizeImage(dataUrl)
  const res = await fetch(resizedDataUrl)
  return res.blob()
}

export async function uploadTicketPhoto(orgId: string, ticketId: string, file: File) {
  const blob = await resizeImageFile(file)
  const path = `${orgId}/${ticketId}/${crypto.randomUUID()}.jpg`
  const { error: uploadError } = await supabase.storage.from("ticket-photos").upload(path, blob, { contentType: "image/jpeg" })
  if (uploadError) throw uploadError
  const { data, error } = await supabase
    .from("service_ticket_photos")
    .insert({ org_id: orgId, ticket_id: ticketId, storage_path: path })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function listTicketPhotos(ticketId: string) {
  const { data, error } = await supabase.from("service_ticket_photos").select("*").eq("ticket_id", ticketId).order("created_at")
  if (error) throw error
  return data
}

export async function ticketPhotoSignedUrl(storagePath: string) {
  const { data, error } = await supabase.storage.from("ticket-photos").createSignedUrl(storagePath, 3600)
  if (error) throw error
  return data.signedUrl
}
