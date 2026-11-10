// Master-only: set a new password for an office-staff login (operation_admin /
// sales_admin). Same show-once contract as admin-create-technician's
// "reset_password" - a generated password is returned once, never stored or
// logged. Technicians have their own reset in admin-create-technician.
//
// Guarded by _shared/staff-auth.ts: the caller's JWT is verified in code and the
// caller must be an ACTIVE master; the target must be operation_admin or
// sales_admin of the caller's own organisation - NEVER a master (including the
// caller: masters change their own password elsewhere); an APPEND-ONLY audit start
// row is written before the password changes (no audit row, no reset) and a separate
// completion row afterwards; a typed password must pass validateTypedPassword;
// after a successful reset the target's sessions and refresh tokens are revoked
// (a reset must also evict someone already holding the old password's session);
// Auth error text is never forwarded; CORS answers only ALLOWED_ORIGINS.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { staffCorsHeaders, staffPreflight } from "../_shared/staff-cors.ts"
import {
  beginStaffAudit,
  checkStaffTarget,
  classifyAuthError,
  finishStaffAudit,
  generatePassword,
  requireActiveMaster,
  revokeUserSessions,
  validateTypedPassword,
} from "../_shared/staff-auth.ts"

Deno.serve(async (req) => {
  const cors = staffCorsHeaders(req)
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } })

  const preflight = staffPreflight(req)
  if (preflight) return preflight
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405)

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "Server is not configured" }, 500)
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })

  const guard = await requireActiveMaster(admin, req.headers.get("Authorization"))
  if (!guard.ok) return json({ error: guard.error }, guard.status)
  const { caller } = guard

  let body: { profileId?: unknown; password?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }
  if (typeof body.profileId !== "string" || !body.profileId) return json({ error: "profileId is required" }, 400)

  const { data: target } = await admin.from("profiles").select("id, org_id, role").eq("id", body.profileId).single()
  const targetCheck = checkStaffTarget(caller, target)
  if (!targetCheck.ok) return json({ error: targetCheck.error }, targetCheck.status)

  // Master may type the password; if omitted, generate one (returned once).
  const typed = typeof body.password === "string" ? body.password : ""
  if (body.password !== undefined && body.password !== null && body.password !== "") {
    const passwordError = validateTypedPassword(body.password)
    if (passwordError) return json({ error: passwordError }, 400)
  }
  const password = typed || generatePassword()

  // Fail closed: the audit start row (who, whom, which role, typed or generated - never the password) comes first.
  const audit = await beginStaffAudit(admin, {
    caller,
    action: "STAFF_PASSWORD_RESET",
    targetId: target!.id,
    details: { target_role: target!.role, generated: !typed },
  })
  if (!audit) return json({ error: "Could not record the audit entry; nothing was changed" }, 500)

  const { error } = await admin.auth.admin.updateUserById(target!.id, { password })
  if (error) {
    const kind = classifyAuthError(error)
    await finishStaffAudit(admin, audit, false, { error: kind === "weak_password" ? "weak_password" : "update_failed" })
    if (kind === "weak_password") return json({ error: "That password is not accepted; choose another or let the system generate one" }, 400)
    return json({ error: "Could not reset the password" }, 400)
  }

  // ORDER MATTERS: the password was changed above, so arming second records the marker of the NEW hash. Arming first would record the
  // old hash and the person could clear the flag without ever choosing a password. If arming fails the password is still reset and
  // the response and the audit row say the change is not forced.
  const { error: flagErr } = await admin.rpc("arm_forced_password_change", { p_profile_id: target!.id })
  const forcedChange = !flagErr

  // A reset must also evict anyone already signed in with the old password.
  const sessionsRevoked = await revokeUserSessions(admin, target!.id)
  await finishStaffAudit(admin, audit, true, { sessions_revoked: sessionsRevoked, forced_change: forcedChange })

  console.log(`admin-reset-staff-password: master ${caller.userId} reset ${target!.id} sessions_revoked=${sessionsRevoked}`)
  return json({ ok: true, generated: !typed, password: typed ? undefined : password, sessionsRevoked, forcedChange })
})
