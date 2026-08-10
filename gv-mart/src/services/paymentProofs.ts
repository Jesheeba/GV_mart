import { supabase } from "@/lib/supabase"
import { fileToDataUrl, resizeImage } from "@/lib/offline/capture"

// Enhancement spec Task 2 — UPI payment proof (screenshot/photo), uploaded
// by the technician right after confirming a UPI payment on-site and stored
// permanently for the admin Customer History / Booking Details audit trail.
// Same resize-then-upload-then-insert shape as ticketPhotos.ts, but no
// geotag/timestamp watermark (that's for on-site evidence photos, not a
// payment screenshot whose pixel content should stay as the customer's app
// rendered it) — and the row itself is written server-side by
// record_payment_proof (SECURITY DEFINER), not a direct table insert; see
// 20260807092000_payment_proofs.sql.

async function resizeImageFile(file: File): Promise<Blob> {
  const dataUrl = await fileToDataUrl(file)
  const resizedDataUrl = await resizeImage(dataUrl)
  const res = await fetch(resizedDataUrl)
  return res.blob()
}

export async function uploadPaymentProof(orgId: string, visitId: string, file: File, transactionReference?: string) {
  const blob = await resizeImageFile(file)
  const path = `${orgId}/${visitId}/${crypto.randomUUID()}.jpg`
  const { error: uploadError } = await supabase.storage.from("payment-proofs").upload(path, blob, { contentType: "image/jpeg" })
  if (uploadError) throw uploadError

  const { data, error } = await supabase.rpc("record_payment_proof", {
    p_org_id: orgId,
    p_visit_id: visitId,
    p_storage_path: path,
    p_transaction_reference: transactionReference?.trim() || null,
  })
  if (error) throw error
  return data as unknown as { ok: boolean; id: string }
}

export async function listPaymentProofsByInvoice(invoiceId: string) {
  const { data, error } = await supabase
    .from("payment_proofs")
    .select("*, technicians(profiles(full_name)), payments(payment_method, paid_at)")
    .eq("invoice_id", invoiceId)
    .order("uploaded_at", { ascending: false })
  if (error) throw error
  return data
}

export async function paymentProofSignedUrl(storagePath: string) {
  const { data, error } = await supabase.storage.from("payment-proofs").createSignedUrl(storagePath, 3600)
  if (error) throw error
  return data.signedUrl
}
