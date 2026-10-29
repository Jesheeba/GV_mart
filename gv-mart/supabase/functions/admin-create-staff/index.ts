// Master-only: create an office-staff login (operation_admin or sales_admin).
//
//   POST { fullName, email, phone?, role, password?, reason? }
//   -> { ok: true, id, email, generated, password? }   (password is returned ONCE, only when generated)
//
// Guarded by _shared/staff-auth.ts and written to be reviewed as a unit:
//   * the caller's JWT is verified in code and the caller must be an ACTIVE master
//     (verify_jwt stays on at the gateway: this function has no config.toml entry);
//   * CORS answers only the origins listed in the ALLOWED_ORIGINS secret (_shared/staff-cors.ts);
//   * the role is an allow-list of two (and the database refuses any client-side write that sets role = master);
//   * the new profile always goes into the CALLER's organisation, active - the request cannot choose either;
//   * a typed password must pass validateTypedPassword (>= 10 bytes, <= 72 bytes, common/predictable refused);
//   * an APPEND-ONLY audit start row (who, email, name, role, optional one-line reason, generated or typed -
//     never the password) is written BEFORE anything is created: no audit row, no account; a separate
//     completion row records the outcome (audit_log forbids UPDATE and DELETE);
//   * if the profile insert fails the auth user is deleted again, so no orphan login is left behind;
//   * Auth error text is never forwarded: only fixed messages;
//   * the password is never logged and never stored anywhere but Supabase Auth.
// Email is the login; there is no email/SMS service, so the master shares the password in person.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { staffCorsHeaders, staffPreflight } from "../_shared/staff-cors.ts"
import { beginStaffAudit, classifyAuthError, finishStaffAudit, generatePassword, requireActiveMaster, validateCreateStaffInput } from "../_shared/staff-auth.ts"

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

  let raw: unknown
  try {
    raw = await req.json()
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }
  const parsed = validateCreateStaffInput(raw)
  if (!parsed.ok) return json({ error: parsed.error }, 400)
  const input = parsed.value

  const generated = input.password === null
  const password = input.password ?? generatePassword()

  // Fail closed: the audit start row comes first. It never contains the password.
  const audit = await beginStaffAudit(admin, {
    caller,
    action: "STAFF_CREATE",
    targetId: null,
    details: { role: input.role, email: input.email, full_name: input.fullName, generated, ...(input.reason ? { reason: input.reason } : {}) },
  })
  if (!audit) return json({ error: "Could not record the audit entry; nothing was created" }, 500)

  const { data: created, error: createErr } = await admin.auth.admin.createUser({ email: input.email, password, email_confirm: true })
  if (createErr || !created?.user) {
    const kind = classifyAuthError(createErr)
    await finishStaffAudit(admin, audit, false, { error: kind === "duplicate_email" ? "duplicate_email" : kind === "weak_password" ? "weak_password" : kind === "invalid_email" ? "invalid_email" : "auth_create_failed" })
    if (kind === "duplicate_email") return json({ error: "A login with this email already exists" }, 409)
    if (kind === "weak_password") return json({ error: "That password is not accepted; choose another or let the system generate one" }, 400)
    if (kind === "invalid_email") return json({ error: "Please enter a valid email address" }, 400)
    return json({ error: "Could not create the login" }, 400)
  }
  const userId = created.user.id

  const { error: profileErr } = await admin.from("profiles").insert({
    id: userId,
    org_id: caller.orgId,
    full_name: input.fullName,
    phone: input.phone,
    role: input.role,
    is_active: true,
  })
  if (profileErr) {
    // roll the login back: an auth user without a profile cannot sign in usefully and would block re-using the email
    const { error: rollbackErr } = await admin.auth.admin.deleteUser(userId)
    await finishStaffAudit(admin, audit, false, { error: "profile_insert_failed", rolled_back: !rollbackErr }, userId)
    console.error("admin-create-staff: profile insert failed", profileErr.code ?? "", rollbackErr ? "ROLLBACK FAILED for " + userId : "rolled back")
    return json({ error: "Could not create the staff profile; nothing was created" }, 500)
  }

  await finishStaffAudit(admin, audit, true, {}, userId)
  console.log(`admin-create-staff: master ${caller.userId} created ${input.role} ${userId}`)
  return json({ ok: true, id: userId, email: input.email, generated, password: generated ? password : undefined })
})
