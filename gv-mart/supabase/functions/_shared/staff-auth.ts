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
