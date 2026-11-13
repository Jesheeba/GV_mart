// Resolves the language and template variables for one pending outbox row, from the record the row points at.
// Thin Supabase adapter around the pure formatters in wa-event-format.ts. Variables that cannot be resolved are left
// null so the template request fails with missing_param:<name> (visible in Failed Sends) instead of sending a blank.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"
import { formatIstDate, formatIstSlot, formatRupees, shortRef } from "./wa-event-format.ts"
import type { DispatchContext, PendingRow } from "./wa-dispatch-v2.ts"

const DB_TIMEOUT_MS = 5_000

type Vars = Record<string, string | null | undefined>

export async function customerLanguageAndName(admin: SupabaseClient, customerId: string | null): Promise<{ language: "en" | "ta"; name: string | null }> {
  if (!customerId) return { language: "en", name: null }
  const { data: c } = await admin
    .from("customers")
    .select("name, primary_profile_id")
    .eq("id", customerId)
    .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
    .maybeSingle()
  const cust = c as { name: string; primary_profile_id: string | null } | null
  let language: "en" | "ta" = "en"
  if (cust?.primary_profile_id) {
    const { data: p } = await admin.from("profiles").select("language").eq("id", cust.primary_profile_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
    if ((p as { language?: string } | null)?.language === "ta") language = "ta"
  }
  return { language, name: cust?.name ?? null }
}

async function technicianNameAndPhone(admin: SupabaseClient, technicianId: string | null): Promise<{ name: string | null; phone: string | null }> {
  if (!technicianId) return { name: null, phone: null }
  const { data: t } = await admin.from("technicians").select("profile_id").eq("id", technicianId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  const profileId = (t as { profile_id?: string } | null)?.profile_id
  if (!profileId) return { name: null, phone: null }
  const { data: p } = await admin.from("profiles").select("full_name, phone").eq("id", profileId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  const profile = p as { full_name?: string; phone?: string } | null
  return { name: profile?.full_name ?? null, phone: profile?.phone ?? null }
}

/** Resolves a product/spare name a service_ticket points at directly (product_id/unlisted_product_name),
 * for templates like gvm_installation_completed that need {{product_name}} off the ticket itself rather
 * than off an invoice line item (installation tickets are not always invoiced yet when they complete). */
async function ticketProductName(admin: SupabaseClient, productId: string | null, unlistedName: string | null): Promise<string | null> {
  if (unlistedName) return unlistedName
  if (!productId) return null
  const { data } = await admin.from("products").select("name").eq("id", productId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  return (data as { name?: string } | null)?.name ?? null
}

async function ticketVars(admin: SupabaseClient, ticketId: string, technicianIdHint: string | null): Promise<Vars> {
  const { data: t } = await admin
    .from("service_tickets")
    .select("id, name_of_complaint, product_id, unlisted_product_name")
    .eq("id", ticketId)
    .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
    .maybeSingle()
  const { data: a } = await admin
    .from("appointments")
    .select("scheduled_at, technician_id")
    .eq("ticket_id", ticketId)
    .order("created_at", { ascending: false })
    .limit(1)
    .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
    .maybeSingle()
  const ticket = t as { id: string; name_of_complaint: string | null; product_id: string | null; unlisted_product_name: string | null } | null
  const appt = a as { scheduled_at: string | null; technician_id: string | null } | null
  const slot = formatIstSlot(appt?.scheduled_at ?? null)
  const tech = await technicianNameAndPhone(admin, technicianIdHint ?? appt?.technician_id ?? null)
  return {
    ticket_ref: shortRef(ticket?.id ?? ticketId),
    complaint: ticket?.name_of_complaint ?? null,
    complaint_number: shortRef(ticket?.id ?? ticketId),
    product_name: ticket ? await ticketProductName(admin, ticket.product_id, ticket.unlisted_product_name) : null,
    technician: tech.name,
    technician_name: tech.name,
    technician_phone: tech.phone,
    slot,
    appointment_time: slot,
  }
}

/** First quotation line item's name (product or spare) — same shape/reasoning as invoiceFirstItemName. */
async function quotationFirstItemName(admin: SupabaseClient, quotationId: string): Promise<string | null> {
  const { data: items } = await admin
    .from("quotation_items")
    .select("item_type, item_id, created_at")
    .eq("quotation_id", quotationId)
    .order("created_at", { ascending: true })
    .limit(1)
    .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
  const item = (items as { item_type: string; item_id: string }[] | null)?.[0]
  if (!item) return null
  const table = item.item_type === "spare" ? "spares" : "products"
  const { data: row } = await admin.from(table).select("name").eq("id", item.item_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  return (row as { name?: string } | null)?.name ?? null
}

/** A single invoice_item row's product/spare name, by its own id — used for a segment's STANDING
 * fire, where payload.invoice_item_id names the exact purchase that triggered it. */
async function invoiceItemName(admin: SupabaseClient, invoiceItemId: string): Promise<string | null> {
  const { data: item } = await admin.from("invoice_items").select("item_type, item_id").eq("id", invoiceItemId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  const row = item as { item_type: string; item_id: string } | null
  if (!row) return null
  const table = row.item_type === "spare" ? "spares" : "products"
  const { data } = await admin.from(table).select("name").eq("id", row.item_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  return (data as { name?: string } | null)?.name ?? null
}

/** A customer's MOST RECENT purchased item name — used for a segment's ONE-OFF "Send Now" fire,
 * where there is no single triggering purchase (the customer may match on any of several). This is
 * a deliberate simplification (see segment-builder build report): it names the latest purchase, not
 * necessarily the specific item that satisfied the segment's own product condition. */
async function customerMostRecentItemName(admin: SupabaseClient, customerId: string): Promise<string | null> {
  const { data: invoices } = await admin
    .from("invoices")
    .select("id")
    .eq("customer_id", customerId)
    .order("created_at", { ascending: false })
    .limit(1)
    .abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS))
  const invoiceId = (invoices as { id: string }[] | null)?.[0]?.id
  if (!invoiceId) return null
  return invoiceFirstItemName(admin, invoiceId)
}

export async function resolveEventContext(admin: SupabaseClient, row: PendingRow): Promise<DispatchContext> {
  const { language, name } = await customerLanguageAndName(admin, row.customer_id)
  const vars: Vars = { name, customer_name: name }
  const appUrl = Deno.env.get("WA_PUBLIC_APP_URL")?.replace(/\/+$/, "") ?? null

  try {
    if (row.ref_type === "service_ticket" && row.ref_id) {
      Object.assign(vars, await ticketVars(admin, row.ref_id, null))
      if (appUrl) vars.summary_link = `${appUrl}/customer/bookings/${row.ref_id}`
    } else if (row.ref_type === "service_visit" && row.ref_id) {
      const { data: v } = await admin.from("service_visits").select("ticket_id, technician_id").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const visit = v as { ticket_id: string; technician_id: string | null } | null
      if (visit?.ticket_id) Object.assign(vars, await ticketVars(admin, visit.ticket_id, visit.technician_id))
    } else if (row.ref_type === "invoice" && row.ref_id) {
      const { data: i } = await admin.from("invoices").select("id, total, created_at").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const inv = i as { id: string; total: number | string; created_at: string } | null
      if (inv) {
        vars.invoice_no = shortRef(inv.id)
        vars.invoice_number = shortRef(inv.id)
        vars.amount = formatRupees(inv.total)
        vars.invoice_date = formatIstDate(inv.created_at)
        // There is no per-invoice customer page or PDF yet (plan open item 4): the link is the customer app home.
        if (appUrl) vars.link = `${appUrl}/customer`
      }
    } else if (row.ref_type === "customer_link_otp") {
      // Phase 2, Item 1 (template discovery): the raw code (written alongside the rendered body
      // text by request_customer_link_code — 20261120100000_customer_link_otp.sql) is the single
      // named parameter the customer_link_otp whatsapp_event_templates row maps to Wasi's
      // 'lexdraft_otp' AUTHENTICATION template. Read directly off payload, never re-derived or
      // looked up elsewhere — there is nowhere else to get it from (only a salted hash is stored
      // in customer_link_otp_challenges). Deliberately no customer name/language override here:
      // customerLanguageAndName above already resolved both correctly for this row.
      vars.code = (row.payload as { code?: string | null } | null)?.code ?? null
    } else if (row.ref_type === "lead" && row.ref_id) {
      // Leads don't always have a customer_id yet (pre-conversion), so customerLanguageAndName above
      // may have resolved name = null — override from the lead's own name/mobile, which always exist.
      const { data: l } = await admin.from("leads").select("name, product_id").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const lead = l as { name: string; product_id: string | null } | null
      if (lead) {
        vars.name = lead.name
        vars.customer_name = lead.name
        vars.enquiry_number = shortRef(row.ref_id)
        if (lead.product_id) {
          const { data: p } = await admin.from("products").select("name").eq("id", lead.product_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
          vars.product_name = (p as { name?: string } | null)?.name ?? null
        }
      }
    } else if (row.ref_type === "quotation" && row.ref_id) {
      const { data: q } = await admin.from("quotations").select("id, total").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const quote = q as { id: string; total: number | string } | null
      if (quote) {
        vars.quotation_number = shortRef(quote.id)
        vars.amount = formatRupees(quote.total)
        vars.product_name = await quotationFirstItemName(admin, quote.id)
      }
    } else if (row.ref_type === "amc_contract" && row.ref_id) {
      const { data: c } = await admin.from("amc_contracts").select("id, expiry_date").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const contract = c as { id: string; expiry_date: string } | null
      if (contract) {
        vars.amc_number = shortRef(contract.id)
        vars.expiry_date = formatIstDate(contract.expiry_date)
      }
    } else if (row.ref_type === "payment" && row.ref_id) {
      // Fired (by _milestone_payment_notify) for any payment -- technician full-payment or
      // master/sales_admin partial top-up -- whose invoice resolves to a real service_tickets
      // row to quote a Complaint No. against. row.ref_id is this one payment row's id, so
      // amount below is this specific installment, not the invoice total.
      const { data: pay } = await admin.from("payments").select("id, amount").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      const payment = pay as { id: string; amount: number | string } | null
      if (payment) {
        vars.amount = formatRupees(payment.amount)
        const ticketId = (row.payload as { ticket_id?: string } | null)?.ticket_id ?? null
        vars.complaint_number = shortRef(ticketId)
      }
    } else if (row.ref_type === "audience_segment_match" && row.customer_id) {
      // row.ref_id is the segment id (constant across its runs); the triggering purchase, when
      // there is one (standing mode only), is payload.invoice_item_id.
      const invoiceItemId = (row.payload as { invoice_item_id?: string } | null)?.invoice_item_id ?? null
      vars.product_name = invoiceItemId ? await invoiceItemName(admin, invoiceItemId) : await customerMostRecentItemName(admin, row.customer_id)
    } else if (row.ref_type === "purchase_quote_request" && row.ref_id) {
      const { data: q } = await admin.from("purchase_quote_requests").select("pdf_url").eq("id", row.ref_id).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
      vars.pdf_url = (q as { pdf_url?: string | null } | null)?.pdf_url ?? null
      const supplierId = (row.payload as { supplier_id?: string } | null)?.supplier_id
      if (supplierId) {
        const { data: s } = await admin.from("suppliers").select("name").eq("id", supplierId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
        vars.supplier_name = (s as { name?: string } | null)?.name ?? null
      }
    }
  } catch (e) {
    // A failed lookup must not stop the send path; unresolved variables surface as missing_param on the row.
    console.error("wa-event-context: variable lookup failed", row.ref_type, e instanceof Error ? e.message : "unknown error")
  }
  return { language, vars }
}
