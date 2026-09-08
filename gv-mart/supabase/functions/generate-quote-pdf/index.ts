// PDF-generation piece of the supplier document-quote-request work
// (compliance investigation, 2026-09-03). Standalone on purpose — Wasi's
// outbound API has no document/media send today, and a document-header
// WhatsApp template needs manual submission via Wasi's own dashboard UI
// (their Hub API has no template-submission endpoint) plus Meta approval,
// timeline unknown, before any send code can consume this PDF's URL. This
// function only builds + stores the PDF and hands back its public URL —
// nothing calls it automatically (not open_monthly_quote_requests, not
// wa-milestone-dispatch); an admin triggers it by hand from the
// Purchase → Quotes tab ("Generate PDF" on an open request).
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"
import { buildQuoteRequestPdf } from "../_shared/quote-pdf.ts"

function jsonError(message: string, status: number) {
  return new Response(JSON.stringify({ error: message }), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}
function jsonOk(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight
  if (req.method !== "POST") return jsonError("Method not allowed", 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) return jsonError("Server is not configured (missing Supabase service credentials)", 500)
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  // ── Authenticate + authorize the caller — same is_ops_staff() gate
  // (master/operation_admin) as resolve_purchase_quote_requests, since this
  // both reads supplier-quote data and writes purchase_quote_requests.pdf_url.
  const authHeader = req.headers.get("Authorization")
  const token = authHeader?.replace(/^Bearer /i, "")
  if (!token) return jsonError("Missing Authorization header", 401)
  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return jsonError("Invalid or expired session", 401)
  const { data: callerProfile, error: callerProfileErr } = await admin.from("profiles").select("org_id, role").eq("id", userRes.user.id).single()
  if (callerProfileErr || !callerProfile) return jsonError("Caller profile not found", 403)
  if (callerProfile.role !== "master" && callerProfile.role !== "operation_admin") {
    return jsonError("Only master or operation_admin may generate a quote PDF", 403)
  }
  const orgId = callerProfile.org_id

  let body: { requestId?: string }
  try {
    body = await req.json()
  } catch {
    return jsonError("Invalid JSON body", 400)
  }
  const requestId = body.requestId
  if (!requestId) return jsonError("requestId is required", 400)

  const { data: request, error: requestErr } = await admin
    .from("purchase_quote_requests")
    .select("id, org_id, item_type, item_id, order_qty, requested_at")
    .eq("id", requestId)
    .eq("org_id", orgId)
    .maybeSingle()
  if (requestErr) return jsonError(requestErr.message, 500)
  if (!request) return jsonError("Quote request not found", 404)

  const { data: org, error: orgErr } = await admin.from("organizations").select("name, address, phone, gst_no").eq("id", orgId).single()
  if (orgErr || !org) return jsonError("Could not load organization details", 500)

  // Item name resolution — same polymorphic products|spares|gifts lookup as
  // _wa_item_display_name / attachQuoteRequestItemNames (client-side), just
  // done here with the service-role client rather than that RPC (which
  // isn't granted to this function's caller and has no reason to be).
  const table = request.item_type === "product" ? "products" : request.item_type === "spare" ? "spares" : "gifts"
  const { data: item } = await admin.from(table).select("name").eq("id", request.item_id).eq("org_id", orgId).maybeSingle()
  const itemName = item?.name ?? "—"

  let pdfBytes: Uint8Array
  try {
    pdfBytes = await buildQuoteRequestPdf({
      orgName: org.name,
      orgAddress: org.address,
      orgPhone: org.phone,
      orgGstNo: org.gst_no,
      itemName,
      orderQty: request.order_qty,
      requestedAt: request.requested_at,
      requestRef: request.id.slice(0, 8).toUpperCase(),
    })
  } catch (e) {
    console.error("generate-quote-pdf: PDF build failed", e)
    return jsonError("Could not build the PDF", 500)
  }

  const path = `${orgId}/${request.id}.pdf`
  const { error: uploadErr } = await admin.storage.from("supplier-quote-pdfs").upload(path, pdfBytes, { contentType: "application/pdf", upsert: true })
  if (uploadErr) {
    console.error("generate-quote-pdf: upload failed", uploadErr)
    return jsonError("Could not store the PDF", 500)
  }

  const { data: publicUrlData } = admin.storage.from("supplier-quote-pdfs").getPublicUrl(path)
  const url = publicUrlData.publicUrl

  const { error: updateErr } = await admin.from("purchase_quote_requests").update({ pdf_url: url }).eq("id", request.id).eq("org_id", orgId)
  if (updateErr) console.error("generate-quote-pdf: failed to save pdf_url on request row", updateErr)

  return jsonOk({ url })
})
