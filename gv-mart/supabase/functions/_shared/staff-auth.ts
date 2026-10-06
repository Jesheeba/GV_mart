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

export async function finishStaffAudit(admin: SupabaseClient, auditId: string, ok: boolean, details: Record<string, unknown> = {}): Promise<void> {
  const { data: row } = await admin.from("audit_log").select("after").eq("id", auditId).single()
  const after = { ...((row?.after as Record<string, unknown> | null) ?? {}), ...details, result: ok ? "ok" : "failed" }
  const { error } = await admin.from("audit_log").update({ after }).eq("id", auditId)
  if (error) console.error("staff-auth: could not complete the audit row", auditId, error.message)
}
