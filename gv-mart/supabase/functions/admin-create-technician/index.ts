// Technician Lifecycle Management, Phase 1. This is the piece the old
// "Add Technician" flow was always missing: creating a brand-new Supabase
// Auth login needs the service_role key, which the browser app correctly
// never ships (see services/techniciansAdmin.ts's old file-header note).
// This function holds that key server-side instead — same pattern as
// supabase/functions/geocode (JWT verification stays on, the project
// default, so only a signed-in staff member can call this at all).
//
// Three actions, all requiring the CALLER to be master/operation_admin
// (checked here explicitly — RLS can't gate an Edge Function call, and
// auth.admin.* bypasses RLS entirely once inside):
//   - "create": provision a new technician end-to-end (auth user + profile +
//     technicians row). Generates the password server-side and returns it
//     once — the admin shares it manually (owner decision: no email/SMS
//     service exists in this project, don't depend on Supabase's SMTP being
//     configured).
//   - "reset_password": generate + set a new password for an existing
//     technician's login, same show-once contract.
//   - "delete": remove a technician's login entirely. `service_visits.
//     technician_id` is `on delete restrict` (20260701090600_service.sql),
//     so this naturally fails for anyone with real job history — that
//     Postgres error is caught and turned into a friendly message rather
//     than deactivation being silently bypassed.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"

type CreateBody = {
  action: "create"
  fullName: string
  phone: string
  email: string
  address?: string | null
  city?: string | null
  state?: string | null
  pincode?: string | null
  skills?: string[]
  zone?: string | null
  dailyCapacityMinutes?: number
  photoUrl?: string | null
}
type ResetPasswordBody = { action: "reset_password"; technicianId: string }
type DeleteBody = { action: "delete"; technicianId: string }
type RequestBody = CreateBody | ResetPasswordBody | DeleteBody

function jsonError(message: string, status: number) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}
function jsonOk(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

/** 12 chars, guaranteed at least one of each class — comfortably clears this project's `minimum_password_length = 6` with room to spare. */
function generatePassword(): string {
  const lower = "abcdefghijkmnpqrstuvwxyz"
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  const digits = "23456789"
  const symbols = "!@#$%*?"
  const all = lower + upper + digits + symbols
  const pick = (chars: string) => chars[Math.floor(Math.random() * chars.length)]
  const required = [pick(lower), pick(upper), pick(digits), pick(symbols)]
  const rest = Array.from({ length: 8 }, () => pick(all))
  const chars = [...required, ...rest]
  for (let i = chars.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[chars[i], chars[j]] = [chars[j], chars[i]]
  }
  return chars.join("")
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight

  if (req.method !== "POST") return jsonError("Method not allowed", 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonError("Server is not configured (missing Supabase service credentials)", 500)
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  // ── Authenticate + authorize the caller (master/operation_admin only) ──
  const authHeader = req.headers.get("Authorization")
  const token = authHeader?.replace(/^Bearer /i, "")
  if (!token) return jsonError("Missing Authorization header", 401)

  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return jsonError("Invalid or expired session", 401)

  const { data: callerProfile, error: callerProfileErr } = await admin
    .from("profiles")
    .select("org_id, role")
    .eq("id", userRes.user.id)
    .single()
  if (callerProfileErr || !callerProfile) return jsonError("Caller profile not found", 403)
  if (callerProfile.role !== "master" && callerProfile.role !== "operation_admin") {
    return jsonError("Only master or operation_admin may manage technicians", 403)
  }
  const orgId = callerProfile.org_id

  let body: RequestBody
  try {
    body = await req.json()
  } catch {
    return jsonError("Invalid JSON body", 400)
  }

  try {
    if (body.action === "create") {
      if (!body.fullName?.trim() || !body.phone?.trim() || !body.email?.trim()) {
        return jsonError("fullName, phone and email are required", 400)
      }
      const password = generatePassword()

      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email: body.email.trim(),
        password,
        email_confirm: true,
        user_metadata: { full_name: body.fullName.trim() },
      })
      if (createErr || !created?.user) {
        return jsonError(createErr?.message ?? "Could not create the login", 400)
      }
      const userId = created.user.id

      // profiles + technicians together; roll back the auth user on any failure
      // after this point so we never leave an orphaned login with no profile.
      const { error: profileErr } = await admin.from("profiles").insert({
        id: userId,
        org_id: orgId,
        full_name: body.fullName.trim(),
        phone: body.phone.trim(),
        role: "technician",
        photo_url: body.photoUrl ?? null,
      })
      if (profileErr) {
        await admin.auth.admin.deleteUser(userId)
        return jsonError(`Could not create the technician's profile: ${profileErr.message}`, 400)
      }

      const { data: technician, error: technicianErr } = await admin
        .from("technicians")
        .insert({
          org_id: orgId,
          profile_id: userId,
          skills: body.skills ?? [],
          zone: body.zone || null,
          address: body.address || null,
          city: body.city || null,
          state: body.state || null,
          pincode: body.pincode || null,
          daily_capacity_minutes: body.dailyCapacityMinutes ?? 480,
          is_active: true,
          is_on_duty: false,
        })
        .select()
        .single()
      if (technicianErr) {
        await admin.auth.admin.deleteUser(userId)
        return jsonError(`Could not create the technician record: ${technicianErr.message}`, 400)
      }

      return jsonOk({ technicianId: technician.id, profileId: userId, password })
    }

    if (body.action === "reset_password") {
      if (!body.technicianId) return jsonError("technicianId is required", 400)
      const { data: technician, error: techErr } = await admin
        .from("technicians")
        .select("profile_id, org_id")
        .eq("id", body.technicianId)
        .single()
      if (techErr || !technician) return jsonError("Technician not found", 404)
      if (technician.org_id !== orgId) return jsonError("Technician not found", 404)

      const password = generatePassword()
      const { error: updateErr } = await admin.auth.admin.updateUserById(technician.profile_id, { password })
      if (updateErr) return jsonError(updateErr.message, 400)

      return jsonOk({ password })
    }

    if (body.action === "delete") {
      if (!body.technicianId) return jsonError("technicianId is required", 400)
      const { data: technician, error: techErr } = await admin
        .from("technicians")
        .select("profile_id, org_id")
        .eq("id", body.technicianId)
        .single()
      if (techErr || !technician) return jsonError("Technician not found", 404)
      if (technician.org_id !== orgId) return jsonError("Technician not found", 404)

      // service_visits.technician_id is ON DELETE RESTRICT, so a technician
      // with real job history can never actually be deleted — checked here
      // proactively rather than parsing auth.admin.deleteUser's error after
      // the fact: GoTrue's cascade-failure response is an opaque `{}`-body
      // 500 (confirmed live), not a message any FK-text regex could match.
      const { count: visitCount, error: visitCheckErr } = await admin
        .from("service_visits")
        .select("id", { count: "exact", head: true })
        .eq("technician_id", body.technicianId)
      if (visitCheckErr) return jsonError(visitCheckErr.message, 400)
      if ((visitCount ?? 0) > 0) {
        return jsonError("Can't delete — this technician has service history. Deactivate instead.", 409)
      }

      const { error: deleteErr } = await admin.auth.admin.deleteUser(technician.profile_id)
      if (deleteErr) return jsonError(deleteErr.message || "Could not delete this technician", 400)
      return jsonOk({ success: true })
    }

    return jsonError("action must be one of: create, reset_password, delete", 400)
  } catch (e) {
    console.error("admin-create-technician error:", e)
    return jsonError("Unexpected server error", 500)
  }
})
