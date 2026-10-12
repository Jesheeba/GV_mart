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

async function technicianName(admin: SupabaseClient, technicianId: string | null): Promise<string | null> {
  if (!technicianId) return null
  const { data: t } = await admin.from("technicians").select("profile_id").eq("id", technicianId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  const profileId = (t as { profile_id?: string } | null)?.profile_id
  if (!profileId) return null
  const { data: p } = await admin.from("profiles").select("full_name").eq("id", profileId).abortSignal(AbortSignal.timeout(DB_TIMEOUT_MS)).maybeSingle()
  return (p as { full_name?: string } | null)?.full_name ?? null
}

async function ticketVars(admin: SupabaseClient, ticketId: string, technicianIdHint: string | null): Promise<Vars> {
  const { data: t } = await admin
    .from("service_tickets")
    .select("id, name_of_complaint")
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
  const ticket = t as { id: string; name_of_complaint: string | null } | null
  const appt = a as { scheduled_at: string | null; technician_id: string | null } | null
  const slot = formatIstSlot(appt?.scheduled_at ?? null)
  return {
    ticket_ref: shortRef(ticket?.id ?? ticketId),
    complaint: ticket?.name_of_complaint ?? null,
    technician: await technicianName(admin, technicianIdHint ?? appt?.technician_id ?? null),
    slot,
    appointment_time: slot,
  }
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
