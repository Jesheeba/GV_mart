// Master-only: generate + set a new password for an admin/staff login
// (master / operation_admin / sales_admin). Same show-once contract as
// admin-create-technician's "reset_password" — the password is returned once,
// never stored or logged. Technicians are deliberately excluded here; they
// have their own reset in admin-create-technician.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"

const STAFF_ROLES = ["master", "operation_admin", "sales_admin"]

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}

/** 14 chars, at least one of each class, drawn from crypto randomness. */
function generatePassword(): string {
  const lower = "abcdefghijkmnpqrstuvwxyz"
  const upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  const digits = "23456789"
  const symbols = "!@#$%*?"
  const all = lower + upper + digits + symbols
  const rand = (n: number) => {
    const buf = new Uint32Array(1)
    crypto.getRandomValues(buf)
    return buf[0] % n
  }
  const pick = (chars: string) => chars[rand(chars.length)]
  const chars = [pick(lower), pick(upper), pick(digits), pick(symbols), ...Array.from({ length: 10 }, () => pick(all))]
  for (let i = chars.length - 1; i > 0; i--) {
    const j = rand(i + 1)
    ;[chars[i], chars[j]] = [chars[j], chars[i]]
  }
  return chars.join("")
}

Deno.serve(async (req) => {
  const preflight = handleCors(req)
  if (preflight) return preflight
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "Server is not configured" }, 500)
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const token = req.headers.get("Authorization")?.replace(/^Bearer /i, "")
  if (!token) return json({ error: "Missing Authorization header" }, 401)
  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return json({ error: "Invalid or expired session" }, 401)

  const { data: caller } = await admin.from("profiles").select("org_id, role").eq("id", userRes.user.id).single()
  if (!caller || caller.role !== "master") return json({ error: "Only master may reset staff passwords" }, 403)

  let body: { profileId?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }
  if (!body.profileId) return json({ error: "profileId is required" }, 400)

  const { data: target } = await admin.from("profiles").select("id, org_id, role").eq("id", body.profileId).single()
  if (!target || target.org_id !== caller.org_id) return json({ error: "Staff member not found" }, 404)
  if (!STAFF_ROLES.includes(target.role)) return json({ error: "Only admin/staff logins can be reset here" }, 400)

  const password = generatePassword()
  const { error } = await admin.auth.admin.updateUserById(target.id, { password })
  if (error) return json({ error: error.message || "Could not reset the password" }, 400)

  console.log(`admin-reset-staff-password: master ${userRes.user.id} reset ${target.id}`)
  return json({ password })
})
