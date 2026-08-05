import { supabase } from "@/lib/supabase"
import { fileToDataUrl, resizeImage } from "@/lib/offline/capture"
import type { TablesInsert, TablesUpdate } from "@/types/database"

// Product Enquiry rebuild (2026-08-04), Phase 1 — product photo/document/
// video management. No Storage bucket existed anywhere in this codebase
// before this feature (see 20260804091000_product_storage_buckets.sql) —
// upload* functions below do the storage.upload() + row-insert in one call
// since every caller needs both together. Deletes only remove the DB row,
// not the underlying storage object — this repo doesn't do storage
// garbage-collection anywhere else either, consistent with keeping this as
// simple as the rest of the masters layer.

function publicUrlFor(bucket: string, path: string) {
  return supabase.storage.from(bucket).getPublicUrl(path).data.publicUrl
}

// ── Images ───────────────────────────────────────────────────────────────
export async function listProductImages(productId: string) {
  const { data, error } = await supabase.from("product_images").select("*").eq("product_id", productId).order("sort_order")
  if (error) throw error
  return data
}

// Product photos display at a fixed square hero/thumbnail size (customer
// detail page, admin media grid) — resizing to fit 800x800 before upload
// keeps large camera-original uploads from bloating storage and load time.
async function resizeImageFile(file: File): Promise<Blob> {
  const dataUrl = await fileToDataUrl(file)
  const resizedDataUrl = await resizeImage(dataUrl)
  const res = await fetch(resizedDataUrl)
  return res.blob()
}

export async function uploadProductImage(orgId: string, productId: string, file: File) {
  const blob = await resizeImageFile(file)
  const path = `${orgId}/${productId}/${crypto.randomUUID()}.jpg`
  const { error: uploadError } = await supabase.storage.from("product-photos").upload(path, blob, { contentType: "image/jpeg" })
  if (uploadError) throw uploadError
  const { data, error } = await supabase
    .from("product_images")
    .insert({ org_id: orgId, product_id: productId, storage_path: path })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateProductImage(id: string, patch: TablesUpdate<"product_images">) {
  const { data, error } = await supabase.from("product_images").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function deleteProductImage(id: string) {
  const { error } = await supabase.from("product_images").delete().eq("id", id)
  if (error) throw error
}

// Swaps the primary flag: unset the current primary (if any) before setting
// the new one, since the DB's partial unique index only allows one
// is_primary=true row per product at a time.
export async function setPrimaryProductImage(productId: string, imageId: string) {
  const { error: unsetError } = await supabase
    .from("product_images")
    .update({ is_primary: false })
    .eq("product_id", productId)
    .eq("is_primary", true)
  if (unsetError) throw unsetError
  const { data, error } = await supabase.from("product_images").update({ is_primary: true }).eq("id", imageId).select().single()
  if (error) throw error
  return data
}

export function productImagePublicUrl(storagePath: string) {
  return publicUrlFor("product-photos", storagePath)
}

// ── Documents ────────────────────────────────────────────────────────────
export async function listProductDocuments(productId: string) {
  const { data, error } = await supabase.from("product_documents").select("*").eq("product_id", productId).order("sort_order")
  if (error) throw error
  return data
}

export async function uploadProductDocument(
  orgId: string,
  productId: string,
  file: File,
  label: string,
  docType: TablesInsert<"product_documents">["doc_type"]
) {
  const path = `${orgId}/${productId}/${crypto.randomUUID()}-${file.name}`
  const { error: uploadError } = await supabase.storage.from("product-documents").upload(path, file)
  if (uploadError) throw uploadError
  const { data, error } = await supabase
    .from("product_documents")
    .insert({ org_id: orgId, product_id: productId, storage_path: path, label, doc_type: docType })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function updateProductDocument(id: string, patch: TablesUpdate<"product_documents">) {
  const { data, error } = await supabase.from("product_documents").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function deleteProductDocument(id: string) {
  const { error } = await supabase.from("product_documents").delete().eq("id", id)
  if (error) throw error
}

export function productDocumentPublicUrl(storagePath: string) {
  return publicUrlFor("product-documents", storagePath)
}

// ── Videos ───────────────────────────────────────────────────────────────
export async function listProductVideos(productId: string) {
  const { data, error } = await supabase.from("product_videos").select("*").eq("product_id", productId).order("sort_order")
  if (error) throw error
  return data
}

export async function createProductVideo(row: TablesInsert<"product_videos">) {
  const { data, error } = await supabase.from("product_videos").insert(row).select().single()
  if (error) throw error
  return data
}

export async function updateProductVideo(id: string, patch: TablesUpdate<"product_videos">) {
  const { data, error } = await supabase.from("product_videos").update(patch).eq("id", id).select().single()
  if (error) throw error
  return data
}

export async function deleteProductVideo(id: string) {
  const { error } = await supabase.from("product_videos").delete().eq("id", id)
  if (error) throw error
}
