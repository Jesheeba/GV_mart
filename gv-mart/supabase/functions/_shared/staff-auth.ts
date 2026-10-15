// Shared guard + audit helpers for the Edge Functions that manage office-staff logins
// (admin-reset-staff-password and admin-create-staff).
//
//   requireActiveMaster  - verifies the JWT in code (verify_jwt stays on at the gateway too),
//                          loads the caller's profile and insists it is an ACTIVE master.
//   checkStaffTarget     - who may be acted on: office staff of the caller's own organisation,
//                          never a master (masters change their own password elsewhere).
//   beginStaffAudit /
//   finishStaffAudit     - APPEND-ONLY audit: a start row is inserted BEFORE the action (fail closed: no
//                          audit row, no action) and a separate completion row is inserted afterwards. The two
//                          rows share a correlation_id in "after"; nothing is ever UPDATEd (audit_log has a
//                          trigger that forbids it). Both rows snapshot the actor's name so attribution survives
//                          the profile being deleted. Neither ever contains a password.
//   validateTypedPassword- one password policy for typed passwords (create and reset).
//   revokeUserSessions   - after a reset, kill the target's sessions and refresh tokens.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2"

export const STAFF_ROLES = ["master", "operation_admin", "sales_admin"] as const
/** Roles an admin-managed password reset may touch. master is deliberately absent. */
export const RESETTABLE_STAFF_ROLES = ["operation_admin", "sales_admin"] as const

export type StaffCaller = { userId: string; orgId: string; fullName: string }
export type GuardResult = { ok: true; caller: StaffCaller } | { ok: false; status: number; error: string }

export async function requireActiveMaster(admin: SupabaseClient, authorizationHeader: string | null): Promise<GuardResult> {
  const token = authorizationHeader?.replace(/^Bearer /i, "")
  if (!token) return { ok: false, status: 401, error: "Missing Authorization header" }
  const { data: userRes, error: userErr } = await admin.auth.getUser(token)
  if (userErr || !userRes?.user) return { ok: false, status: 401, error: "Invalid or expired session" }

  const { data: profile } = await admin.from("profiles").select("org_id, role, is_active, full_name").eq("id", userRes.user.id).single()
  if (!profile || profile.role !== "master" || profile.is_active !== true) {
    return { ok: false, status: 403, error: "Only an active master may manage staff logins" }
  }
  return { ok: true, caller: { userId: userRes.user.id, orgId: profile.org_id as string, fullName: String(profile.full_name ?? "") } }
}

export type StaffTarget = { id: string; org_id: string; role: string }
export type TargetResult = { ok: true } | { ok: false; status: number; error: string }

export function checkStaffTarget(caller: StaffCaller, target: StaffTarget | null): TargetResult {
  if (!target || target.org_id !== caller.orgId) return { ok: false, status: 404, error: "Staff member not found" }
  if (target.role === "master") return { ok: false, status: 403, error: "Masters change their own password elsewhere; it cannot be reset here" }
  if (!(RESETTABLE_STAFF_ROLES as readonly string[]).includes(target.role)) return { ok: false, status: 400, error: "Only operation_admin and sales_admin logins can be reset here" }
  return { ok: true }
}

// ── audit (append-only) ──────────────────────────────────────────────────

export type StaffAuditAction = "STAFF_PASSWORD_RESET" | "STAFF_CREATE"
export type StaffAudit = { correlationId: string; caller: StaffCaller; action: StaffAuditAction; targetId: string | null }

/** Inserts the START row. Returns the handle, or null if it could not be written (the caller must then refuse the action). */
export async function beginStaffAudit(
  admin: SupabaseClient,
  a: { caller: StaffCaller; action: StaffAuditAction; targetId: string | null; details: Record<string, unknown> }
): Promise<StaffAudit | null> {
  const correlationId = crypto.randomUUID()
  const { error } = await admin.from("audit_log").insert({
    org_id: a.caller.orgId,
    actor_id: a.caller.userId,
    action: a.action,
    table_name: "profiles",
    row_id: a.targetId,
    before: null,
    after: { phase: "start", result: "pending", correlation_id: correlationId, actor_name: a.caller.fullName, ...a.details },
  })
  if (error) {
    console.error("staff-auth: could not write the audit start row", a.action, error.message)
    return null
  }
  return { correlationId, caller: a.caller, action: a.action, targetId: a.targetId }
}

/** Inserts the COMPLETION row (a separate row, never an UPDATE). A missing completion row means the outcome is unknown. */
export async function finishStaffAudit(
  admin: SupabaseClient,
  audit: StaffAudit,
  ok: boolean,
  details: Record<string, unknown> = {},
  rowId?: string
): Promise<boolean> {
  const { error } = await admin.from("audit_log").insert({
    org_id: audit.caller.orgId,
    actor_id: audit.caller.userId,
    action: audit.action,
    table_name: "profiles",
    row_id: rowId ?? audit.targetId,
    before: null,
    after: { phase: "result", result: ok ? "ok" : "failed", correlation_id: audit.correlationId, actor_name: audit.caller.fullName, ...details },
  })
  if (error) {
    console.error("staff-auth: could not write the audit completion row", audit.correlationId, error.message)
    return false
  }
  return true
}

// ── Auth error mapping (fixed messages; never forward GoTrue's text) ─────────

export type AuthFailure = "duplicate_email" | "weak_password" | "other"

/** GoTrue reports an existing email with code "email_exists" (older versions: a message containing "already registered"). A bare 422 is NOT enough: a weak password is also a 422. */
export function classifyAuthError(err: { message?: string; code?: string } | null | undefined): AuthFailure {
  if (!err) return "other"
  if (err.code === "email_exists" || /already (been )?registered|already exists/i.test(err.message ?? "")) return "duplicate_email"
  if (err.code === "weak_password" || /password (should|must)|weak password/i.test(err.message ?? "")) return "weak_password"
  return "other"
}

// ── session revocation (F-01) ────────────────────────────────────────────

/**
 * Deletes the user's sessions and refresh tokens through the service-role-only definer function
 * public.revoke_user_sessions. Returns false (and logs the user id only) if it could not be done.
 */
export async function revokeUserSessions(admin: SupabaseClient, userId: string): Promise<boolean> {
  const { error } = await admin.rpc("revoke_user_sessions", { p_user_id: userId })
  if (error) {
    console.error("staff-auth: could not revoke sessions for", userId, error.code ?? "")
    return false
  }
  return true
}

// ── typed passwords (F-04) ───────────────────────────────────────────────

export const MIN_PASSWORD_BYTES = 10
export const MAX_PASSWORD_BYTES = 72 // bcrypt only reads the first 72 BYTES

/** Lower-cased exact matches that are refused. Not exhaustive: it blocks the obvious ones. */
export const COMMON_PASSWORDS: ReadonlySet<string> = new Set([
  "password", "password1", "password12", "password123", "password1234", "passw0rd", "p@ssw0rd", "p@ssword", "p@ssword1", "pass1234", "pass12345",
  "123456", "1234567", "12345678", "123456789", "1234567890", "12345678910", "0123456789", "0987654321", "1111111111", "0000000000", "9876543210",
  "qwerty", "qwerty123", "qwertyuiop", "qwerty1234", "qwertyuiop123", "asdfghjkl", "asdfghjkl1", "zxcvbnm123", "1q2w3e4r5t", "1qaz2wsx3edc",
  "iloveyou", "iloveyou1", "welcome", "welcome1", "welcome123", "welcome@123", "admin", "admin123", "admin1234", "admin@123", "administrator",
  "letmein", "letmein123", "changeme", "changeme123", "abc123", "abcd1234", "abcdefghij", "abc12345", "monkey123", "dragon123", "football1",
  "sachin123", "india123", "india@123", "krishna123", "krishna@123", "ganesh123", "murugan123", "chennai123", "tamilnadu1", "tamil123",
  "gvmart", "gvmart123", "gvmart@123", "gvmart1234", "gvmart2026", "sales123", "sales@123", "salesperson1", "operation1", "operations1",
])

function isSingleRepeatedChar(s: string): boolean {
  return s.length > 1 && [...s].every((ch) => ch === s[0])
}

/** True when every character steps by +1 (or -1) from the previous one, e.g. "abcdefghij", "9876543210". */
function isSequentialRun(s: string): boolean {
  const codes = [...s].map((ch) => ch.charCodeAt(0))
  if (codes.length < 3) return false
  const step = codes[1] - codes[0]
  if (Math.abs(step) !== 1) return false
  return codes.every((c, i) => i === 0 || c - codes[i - 1] === step)
}

/** Returns a user-facing error, or null when the typed password is acceptable. Length is counted in BYTES. */
export function validateTypedPassword(pw: unknown): string | null {
  if (typeof pw !== "string") return "Password must be text"
  const bytes = new TextEncoder().encode(pw).length
  if (bytes < MIN_PASSWORD_BYTES || bytes > MAX_PASSWORD_BYTES) return `Password must be ${MIN_PASSWORD_BYTES}-${MAX_PASSWORD_BYTES} bytes long`
  const lower = pw.toLowerCase().trim()
  if (COMMON_PASSWORDS.has(lower) || /password|qwerty|letmein|gvmart/.test(lower)) return "That password is too common; choose another or let the system generate one"
  if (isSingleRepeatedChar(pw) || isSequentialRun(lower)) return "That password is too predictable; choose another or let the system generate one"
  return null
}

// ── creating a staff login (admin-create-staff) ──────────────────────────
/** Roles a master may CREATE here. master is deliberately absent. (The database also refuses any client-side write that sets role = master.) */
export const CREATABLE_STAFF_ROLES = ["operation_admin", "sales_admin"] as const
export type CreatableStaffRole = (typeof CREATABLE_STAFF_ROLES)[number]

export type CreateStaffInput = {
  fullName: string
  email: string
  phone: string | null
  role: CreatableStaffRole
  /** Free-text job title shown in staff lists (1-80 chars), or null. */
  designation: string | null
  /** Postal address, up to 300 characters, or null. */
  address: string | null
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
    const passwordError = validateTypedPassword(b.password)
    if (passwordError) return { ok: false, error: passwordError }
    password = b.password as string
  }

  const designation = str(b.designation)
  if (designation.length > 80 || hasControlChars(designation)) return { ok: false, error: "Designation must be a single line of at most 80 characters" }

  // an address may span lines (newline is allowed), but no other control characters
  const address = typeof b.address === "string" ? b.address.trim() : ""
  if (address.length > 300 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(address)) return { ok: false, error: "Address must be at most 300 characters" }

  const rawReason = str(b.reason)
  if (rawReason.length > 200 || hasControlChars(rawReason)) return { ok: false, error: "Reason must be a single line of at most 200 characters" }

  return {
    ok: true,
    value: { fullName, email, phone, role: role as CreatableStaffRole, designation: designation || null, address: address || null, password, reason: rawReason || null },
  }
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
