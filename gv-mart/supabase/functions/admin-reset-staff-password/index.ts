// Master-only: set a new password for an office-staff login (operation_admin /
// sales_admin). Same show-once contract as admin-create-technician's
// "reset_password" - a generated password is returned once, never stored or
// logged. Technicians have their own reset in admin-create-technician.
//
// Guarded by _shared/staff-auth.ts: the caller's JWT is verified in code and the
// caller must be an ACTIVE master; the target must be operation_admin or
// sales_admin of the caller's own organisation - NEVER a master (including the
// caller: masters change their own password elsewhere); and an audit_log row is
// written before the password changes (no audit row, no reset).
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"
import { beginStaffAudit, checkStaffTarget, finishStaffAudit, requireActiveMaster } from "../_shared/staff-auth.ts"

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

  const guard = await requireActiveMaster(admin, req.headers.get("Authorization"))
  if (!guard.ok) return json({ error: guard.error }, guard.status)
  const { caller } = guard

  let body: { profileId?: string; password?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }
  if (!body.profileId) return json({ error: "profileId is required" }, 400)

  const { data: target } = await admin.from("profiles").select("id, org_id, role").eq("id", body.profileId).single()
  const targetCheck = checkStaffTarget(caller, target)
  if (!targetCheck.ok) return json({ error: targetCheck.error }, targetCheck.status)

  // Master may type the password; if omitted, generate one (returned once).
  const typed = typeof body.password === "string" ? body.password : ""
  if (typed && (typed.length < 8 || typed.length > 72)) return json({ error: "Password must be 8-72 characters" }, 400)
  const password = typed || generatePassword()

  // Fail closed: the audit row (who, whom, which role, typed or generated - never the password) comes first.
  const auditId = await beginStaffAudit(admin, {
    orgId: caller.orgId,
    actorId: caller.userId,
    action: "STAFF_PASSWORD_RESET",
    targetId: target!.id,
    details: { target_role: target!.role, generated: !typed },
  })
  if (!auditId) return json({ error: "Could not record the audit entry; nothing was changed" }, 500)

  const { error } = await admin.auth.admin.updateUserById(target!.id, { password })
  if (error) {
    await finishStaffAudit(admin, auditId, false, { error: error.message || "update failed" })
    return json({ error: error.message || "Could not reset the password" }, 400)
  }
  await finishStaffAudit(admin, auditId, true)

  console.log(`admin-reset-staff-password: master ${caller.userId} reset ${target!.id}`)
  return json({ ok: true, generated: !typed, password: typed ? undefined : password })
})
