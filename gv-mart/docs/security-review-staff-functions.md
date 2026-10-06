# Security review packet: staff-login Edge Functions

Prepared 2026-10-06 on branch `leads-phase2` (base commit `66ac5b5` plus the uncommitted work described below).
**Nothing in this packet is deployed.** Both functions are reviewed here first; deploy only after sign-off.

| Item | Status |
|---|---|
| `admin-reset-staff-password` (already on GitHub main, hardened in commit `2fb0417`) | **Not deployed since hardening.** The version live today is the OLD one: any master or the caller can be a target, no active-caller check, no audit row. |
| `admin-create-staff` (new) | Not deployed. Not on GitHub main yet. |
| `_shared/staff-auth.ts` | Shared guard, target check, audit helpers, input validation, password generator. |

## 1. What the two functions do

* **admin-reset-staff-password** - a master sets a new password (typed, or generated and shown once) for an `operation_admin` or `sales_admin` login in their own organisation.
* **admin-create-staff** - a master creates a new `operation_admin` or `sales_admin` login (email is the login, phone optional, optional one-line reason for the audit row, typed or generated password). There is no email/SMS service: the master hands the password over in person.

Both: POST only, CORS `*` (calls come from the browser app with a bearer token, no cookies), called through `supabase.functions.invoke` from the HR page.

## 2. Trust model and controls

1. **Authentication.** `verify_jwt` is left at the project default (on): neither function has a `config.toml` entry. In addition the code verifies the token itself with `admin.auth.getUser(token)`; the anon key is therefore rejected (401).
2. **Authorisation.** The caller's profile must be `role = master` AND `is_active = true`, else 403. A signed-in user without a profile also gets 403.
3. **No privilege escalation.** Create: role is an allow-list of exactly `operation_admin` and `sales_admin` (a `master`, `technician` or `customer` is a 400). Reset: any `master` target is refused (403), including the caller; technicians and customers are refused (400).
4. **Tenant isolation.** The new profile always gets the CALLER's `org_id` and `is_active = true`; the request cannot supply `org_id`, `id` or `is_active` (ignored, unit-tested). Reset targets in another organisation are "not found" (404).
5. **Audit, fail closed.** An `audit_log` row (`STAFF_CREATE` or `STAFF_PASSWORD_RESET`) is inserted BEFORE the action: actor, target, role, typed-or-generated, and for create the email, name and optional reason. If it cannot be written the action is not performed (500). The row is completed with `result: ok|failed` afterwards (and, for create, the new user's id is set as `row_id`). Passwords are never part of it.
6. **No secrets in logs or responses.** The only log lines are ids (`master <id> created <role> <id>`). The password is returned once, only when generated; a typed password is never echoed.
7. **No orphan logins.** If the profile insert fails after the auth user is created, the auth user is deleted again; the audit row records `rolled_back`. A failed rollback is logged with the user id for manual cleanup.
8. **Duplicate email** returns 409 (GoTrue `email_exists`); a weak-password 422 is deliberately NOT treated as a duplicate.

## 3. Threat list

| # | Threat | Mitigation | Evidence |
|---|---|---|---|
| T1 | Anonymous caller or forged/expired token | Gateway JWT check plus `auth.getUser` in code; anon key is not a user | handler tests: 401 for no header and for an unknown token |
| T2 | A non-master (sales_admin, technician) calls the function | 403 | tests |
| T3 | An INACTIVE master (deactivated owner, stolen old session) | `is_active` required | tests: 403 |
| T4 | Creating a master or any other privileged account | allow-list of two roles; client cannot choose org/id/is_active | validation tests, handler tests |
| T5 | Taking over another master's account by resetting the password | any master target refused, including self | tests |
| T6 | Cross-organisation access | org taken from the caller; foreign target is 404 | tests |
| T7 | Password leakage via logs, audit rows or API responses | never logged, never in audit; shown once; typed password not echoed | tests assert the strings are absent from console output and audit rows |
| T8 | Action without a trace | audit row first, fail closed | tests: audit failure leaves no account and no password change |
| T9 | Half-created account | rollback of the auth user; audit says so | test |
| T10 | Email enumeration | the 409 reveals an email exists, but only to an active master | accepted |
| T11 | Brute force or mass creation by a compromised master token | no rate limit in the function; every creation is audited and masters cannot be created | accepted residual, see section 5 |
| T12 | CORS `*` | bearer-token auth, no cookies/credentials, so cross-site requests cannot ride a session | accepted |
| T13 | Race: two creates for one email | Auth unique constraint: one succeeds, one gets 409 | by design |
| T14 | Target role changes between the check and the password update | tiny window, master-only caller, audited | accepted |
| T15 | Weak passwords | server enforces 8-72 characters for a typed password; generated ones are 14 characters with four classes from crypto randomness | tests |
| T16 | Audit rows can be deleted by someone with database access | the table has no immutability trigger | **open item for the reviewer**: consider making `audit_log` append-only |

## 4. How it was tested (all without deploying)

* `staff-auth.test.ts` - guard, target check, audit helpers, input validation, password generator (21 tests).
* `admin-reset-staff-password.handler.test.ts` - the REAL `index.ts` handler run in Node with a fake Deno runtime and a fake service-role client (10 tests: 401, 403 for non-master and inactive master, 403 for any master target including the caller, 404/400, audit written first, fail-closed audit, failed-update audit, password absent from logs and audit).
* `admin-create-staff.handler.test.ts` - the REAL `index.ts` handler the same way (11 tests: 401, 403 x3, 400 for master/technician/customer and bad input, success with audit-first call order, org taken from the caller, duplicate 409, weak-password not mistaken for a duplicate, rollback, fail-closed audit, no secrets in logs).
* UI check against the live database with the function call mocked in the browser (dialog validation, role menu offers only Sales and Operations, payload contains no org/id/is_active, show-once reveal, no WhatsApp link).
* Limit: the functions have NOT been run under real Deno against a real Auth server. Before any deploy there is no way to do that without deploying; the first live test is the post-deploy plan below.

## 5. Residual risks and decisions for the reviewer

1. No "must change password at first login" yet (feasibility note in the covering message). Today the master hands over a password they know.
2. No rate limiting; relies on master-only access plus audit.
3. T16 above (audit_log is not append-only).
4. The reset function previously let a master reset another master; the hardening changes behaviour: masters must change their own password through Supabase's own flow.

## 6. Post-deploy test plan (throwaway users only, everything deleted afterwards, including their audit rows)

anon key -> 401; sales_admin -> 403; deactivated master -> 403; role master/technician/customer -> 400; duplicate email -> 409; success creates auth user, profile in the caller's organisation, exactly one audit row, and the generated password logs in; the password appears in no audit row; reset of a master (another and self) -> 403; reset of a sales_admin works and writes an audit row; a failed profile insert leaves no auth user (needs fault injection, so covered by the unit test only).

Deploy command (when approved), one function at a time, no new CLI install: `npx supabase functions deploy admin-create-staff --project-ref fsunrjithwcjtsutsgea` and `npx supabase functions deploy admin-reset-staff-password --project-ref fsunrjithwcjtsutsgea`. Before deploying, `git diff` the function directories against what is live.

---

## Appendix A: `supabase/functions/_shared/staff-auth.ts`

```ts
// Shared guard + audit helpers for the Edge Functions that manage office-staff logins
// (admin-reset-staff-password today; the planned admin-create-staff next).
//
//   requireActiveMaster  - verifies the JWT in code (verify_jwt stays on at the gateway too),
//                          loads the caller's profile and insists it is an ACTIVE master.
//   checkStaffTarget     - who may be acted on: office staff of the caller's own organisation,
//                          never a master (masters change their own password elsewhere).
//   beginStaffAudit /
//   finishStaffAudit     - an audit_log row written BEFORE the action (fail closed: no audit row,
//                          no action) and completed with the outcome afterwards. It records actor,
//                          target and role; it never contains a password.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export const STAFF_ROLES = ["master", "operation_admin", "sales_admin"] as const
/** Roles an admin-managed password reset may touch. master is deliberately absent. */
export const RESETTABLE_STAFF_ROLES = ["operation_admin", "sales_admin"] as const

export type StaffCaller = { userId: string; orgId: string }
export type GuardResult = { ok: true; caller: StaffCaller } | { ok: false; status: number; error: string }

export async function requireActiveMaster(admin: SupabaseClient, authorizationHeader: string | null): Promise<GuardResult> {
  const token = authorizationHeader?.replace(/^Bearer /i, "")
  if (!token) return { ok: false, status: 401, error: "Missing Authorization header" }
  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return { ok: false, status: 401, error: "Invalid or expired session" }

  const { data: profile } = await admin.from("profiles").select("org_id, role, is_active").eq("id", userRes.user.id).single()
  if (!profile || profile.role !== "master" || profile.is_active !== true) {
    return { ok: false, status: 403, error: "Only an active master may manage staff logins" }
  }
  return { ok: true, caller: { userId: userRes.user.id, orgId: profile.org_id as string } }
}

export type StaffTarget = { id: string; org_id: string; role: string }
export type TargetResult = { ok: true } | { ok: false; status: number; error: string }

export function checkStaffTarget(caller: StaffCaller, target: StaffTarget | null): TargetResult {
  if (!target || target.org_id !== caller.orgId) return { ok: false, status: 404, error: "Staff member not found" }
  if (target.role === "master") return { ok: false, status: 403, error: "Masters change their own password elsewhere; it cannot be reset here" }
  if (!(RESETTABLE_STAFF_ROLES as readonly string[]).includes(target.role)) return { ok: false, status: 400, error: "Only operation_admin and sales_admin logins can be reset here" }
  return { ok: true }
}

export type StaffAuditAction = "STAFF_PASSWORD_RESET" | "STAFF_CREATE"

/** Inserts the audit row up front. Returns its id, or null if it could not be written (the caller must then refuse the action). */
export async function beginStaffAudit(
  admin: SupabaseClient,
  a: { orgId: string; actorId: string; action: StaffAuditAction; targetId: string | null; details: Record<string, unknown> }
): Promise<string | null> {
  const { data, error } = await admin
    .from("audit_log")
    .insert({ org_id: a.orgId, actor_id: a.actorId, action: a.action, table_name: "profiles", row_id: a.targetId, before: null, after: { result: "pending", ...a.details } })
    .select("id")
    .single()
  if (error || !data) {
    console.error("staff-auth: could not write the audit row", a.action, error?.message)
    return null
  }
  return data.id as string
}

export async function finishStaffAudit(
  admin: SupabaseClient,
  auditId: string,
  ok: boolean,
  details: Record<string, unknown> = {},
  rowId?: string
): Promise<void> {
  const { data: row } = await admin.from("audit_log").select("after").eq("id", auditId).single()
  const after = { ...((row?.after as Record<string, unknown> | null) ?? {}), ...details, result: ok ? "ok" : "failed" }
  const patch: Record<string, unknown> = rowId ? { after, row_id: rowId } : { after }
  const { error } = await admin.from("audit_log").update(patch).eq("id", auditId)
  if (error) console.error("staff-auth: could not complete the audit row", auditId, error.message)
}

// ── creating a staff login (admin-create-staff) ──────────────────────────
/** Roles a master may CREATE here. master is deliberately absent: no function can mint a master. */
export const CREATABLE_STAFF_ROLES = ["operation_admin", "sales_admin"] as const
export type CreatableStaffRole = (typeof CREATABLE_STAFF_ROLES)[number]

export type CreateStaffInput = {
  fullName: string
  email: string
  phone: string | null
  role: CreatableStaffRole
  /** Typed password, or null when the server should generate one. */
  password: string | null
  reason: string | null
}
export type CreateStaffValidation = { ok: true; value: CreateStaffInput } | { ok: false; error: string }

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
/** True when the text contains an ASCII control character (including newlines and tabs). */
function hasControlChars(text: string): boolean {
  for (let k = 0; k < text.length; k++) {
    const c = text.charCodeAt(k)
    if (c < 32 || c === 127) return true
  }
  return false
}

/** Pure validation of the request body; never trusts a client-supplied org, id or is_active. */
export function validateCreateStaffInput(body: unknown): CreateStaffValidation {
  const b = (body ?? {}) as Record<string, unknown>
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "")

  const fullName = str(b.fullName)
  if (fullName.length < 2 || fullName.length > 80 || hasControlChars(fullName)) return { ok: false, error: "Full name must be 2-80 characters" }

  const email = str(b.email).toLowerCase()
  if (email.length > 254 || !EMAIL_RE.test(email)) return { ok: false, error: "A valid email address is required" }

  const role = b.role
  if (typeof role !== "string" || !(CREATABLE_STAFF_ROLES as readonly string[]).includes(role)) {
    return { ok: false, error: "Role must be operation_admin or sales_admin" }
  }

  let phone: string | null = null
  const rawPhone = str(b.phone)
  if (rawPhone) {
    let digits = rawPhone.replace(/\D/g, "")
    if (digits.length === 12 && digits.startsWith("91")) digits = digits.slice(2)
    if (digits.length !== 10) return { ok: false, error: "Phone must be a 10-digit mobile number" }
    phone = digits
  }

  let password: string | null = null
  if (b.password !== undefined && b.password !== null && b.password !== "") {
    if (typeof b.password !== "string" || b.password.length < 8 || b.password.length > 72) return { ok: false, error: "Password must be 8-72 characters" }
    password = b.password
  }

  const rawReason = str(b.reason)
  if (rawReason.length > 200 || hasControlChars(rawReason)) return { ok: false, error: "Reason must be a single line of at most 200 characters" }

  return { ok: true, value: { fullName, email, phone, role: role as CreatableStaffRole, password, reason: rawReason || null } }
}

/** 14 chars, at least one of each class, drawn from crypto randomness. */
export function generatePassword(): string {
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
```

## Appendix B: `supabase/functions/admin-create-staff/index.ts`

```ts
// Master-only: create an office-staff login (operation_admin or sales_admin).
//
//   POST { fullName, email, phone?, role, password?, reason? }
//   -> { ok: true, id, email, generated, password? }   (password is returned ONCE, only when generated)
//
// Guarded by _shared/staff-auth.ts and written to be reviewed as a unit:
//   * the caller's JWT is verified in code and the caller must be an ACTIVE master
//     (verify_jwt stays on at the gateway: this function has no config.toml entry);
//   * the role is an allow-list of two: a master, technician or customer can never be created here;
//   * the new profile always goes into the CALLER's organisation, active - the request cannot choose either;
//   * an audit_log row (STAFF_CREATE: who, email, name, role, optional one-line reason, generated or typed -
//     never the password) is written BEFORE anything is created: no audit row, no account;
//   * if the profile insert fails the auth user is deleted again, so no orphan login is left behind;
//   * the password is never logged and never stored anywhere but Supabase Auth.
// Email is the login; there is no email/SMS service, so the master shares the password in person.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { corsHeaders, handleCors } from "../_shared/cors.ts"
import { beginStaffAudit, finishStaffAudit, generatePassword, requireActiveMaster, validateCreateStaffInput } from "../_shared/staff-auth.ts"

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } })
}

/** GoTrue reports an existing email with code "email_exists" (older versions: a message containing "already registered"). A bare 422 is NOT enough: a weak password is also a 422. */
function isDuplicateEmail(err: { message?: string; code?: string }): boolean {
  return err.code === "email_exists" || /already (been )?registered|already exists/i.test(err.message ?? "")
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

  // Fail closed: the audit row comes first. It never contains the password.
  const auditId = await beginStaffAudit(admin, {
    orgId: caller.orgId,
    actorId: caller.userId,
    action: "STAFF_CREATE",
    targetId: null,
    details: { role: input.role, email: input.email, full_name: input.fullName, generated, ...(input.reason ? { reason: input.reason } : {}) },
  })
  if (!auditId) return json({ error: "Could not record the audit entry; nothing was created" }, 500)

  const { data: created, error: createErr } = await admin.auth.admin.createUser({ email: input.email, password, email_confirm: true })
  if (createErr || !created?.user) {
    const duplicate = !!createErr && isDuplicateEmail(createErr)
    await finishStaffAudit(admin, auditId, false, { error: duplicate ? "duplicate_email" : "auth_create_failed" })
    return duplicate ? json({ error: "A login with this email already exists" }, 409) : json({ error: "Could not create the login" }, 400)
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
    await finishStaffAudit(admin, auditId, false, { error: "profile_insert_failed", rolled_back: !rollbackErr })
    console.error("admin-create-staff: profile insert failed", profileErr.message, rollbackErr ? "ROLLBACK FAILED for " + userId : "rolled back")
    return json({ error: "Could not create the staff profile; nothing was created" }, 500)
  }

  await finishStaffAudit(admin, auditId, true, {}, userId)
  console.log(`admin-create-staff: master ${caller.userId} created ${input.role} ${userId}`)
  return json({ ok: true, id: userId, email: input.email, generated, password: generated ? password : undefined })
})
```

## Appendix C: `supabase/functions/admin-reset-staff-password/index.ts` (hardened, commit 2fb0417)

```ts
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
```
