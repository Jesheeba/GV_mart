// Master-only: deactivate or reactivate a SALES PERSON (sales_admin). NOT DEPLOYED (design: docs/design-admin-set-staff-active.md).
//
// Deactivation must (1) cut access at once, (2) block login, (3) revoke sessions, (4) return the person's work
// (leads flagged "needs reassignment", follow-ups and tasks to the acting master), (5) leave an immutable record.
//
//   1. guard      requireActiveMaster; target must be a sales_admin of the caller's organisation, never a master,
//                 never the caller. An unchanged state is an idempotent no-op that still writes the audit pair.
//   2. audit      append-only START row first (fail closed: no row, no action).
//   3. database   set_sales_person_active (service-role-only definer RPC, one transaction) flips is_active and moves
//                 the work. This step alone cuts all data access (is_staff()/is_sales_staff()/current_role()).
//   4. ban        updateUserById ban_duration (reactivation: 'none').
//   5. sessions   revoke_user_sessions (deactivation only).
//   6. completion append-only RESULT row with the three step outcomes and the counts.
// Reactivation runs the steps in the opposite order (unban first, then set active) so a failure never grants access.
// Every step is idempotent, so a partial result is fixed by simply repeating the request.
import { createClient } from "jsr:@supabase/supabase-js@2"
import { staffCorsHeaders, staffPreflight } from "../_shared/staff-cors.ts"
import { beginStaffAudit, finishStaffAudit, requireActiveMaster, revokeUserSessions } from "../_shared/staff-auth.ts"

const BAN_FOREVER = "876000h" // 100 years: GoTrue has no permanent ban, this is the documented idiom

type Step = "ok" | "failed" | "skipped"

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

  let body: { profileId?: unknown; active?: unknown; reason?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body" }, 400)
  }
  if (typeof body.profileId !== "string" || !body.profileId) return json({ error: "profileId is required" }, 400)
  if (typeof body.active !== "boolean") return json({ error: "active must be true or false" }, 400)
  const active = body.active
  const reason = typeof body.reason === "string" ? body.reason.trim().slice(0, 200) : ""

  const { data: target } = await admin.from("profiles").select("id, org_id, role, is_active").eq("id", body.profileId).single()
  if (!target || target.org_id !== caller.orgId) return json({ error: "Staff member not found" }, 404)
  if (target.id === caller.userId || target.role === "master") return json({ error: "A master cannot be changed here" }, 403)
  if (target.role !== "sales_admin") return json({ error: "Only sales persons can be activated or deactivated here" }, 400)

  // Fail closed: the audit start row (who, whom, which direction, optional reason) comes first.
  const audit = await beginStaffAudit(admin, {
    caller,
    action: active ? "STAFF_REACTIVATE" : "STAFF_DEACTIVATE",
    targetId: target.id,
    details: { target_role: target.role, was_active: target.is_active, requested_active: active, reason: reason || null },
  })
  if (!audit) return json({ error: "Could not record the audit entry; nothing was changed" }, 500)

  const steps: { db: Step; ban: Step; sessions: Step } = { db: "skipped", ban: "skipped", sessions: "skipped" }
  let counts: Record<string, unknown> = {}

  const setBan = async (ban: boolean): Promise<Step> => {
    const { error } = await admin.auth.admin.updateUserById(target.id, { ban_duration: ban ? BAN_FOREVER : "none" })
    if (error) {
      console.error("admin-set-staff-active: ban update failed for", target.id, error.code ?? "")
      return "failed"
    }
    return "ok"
  }
  const setDb = async (): Promise<Step> => {
    const { data, error } = await admin.rpc("set_sales_person_active", { p_actor: caller.userId, p_profile_id: target.id, p_active: active })
    if (error) {
      console.error("admin-set-staff-active: database step failed for", target.id, error.code ?? "")
      return "failed"
    }
    counts = (data ?? {}) as Record<string, unknown>
    return "ok"
  }

  if (active) {
    // reactivation: unban first, then set active. A failure leaves the person inactive (no access).
    steps.ban = await setBan(false)
    if (steps.ban === "ok") steps.db = await setDb()
  } else {
    // deactivation: database first (this alone cuts data access), then ban, then sessions.
    steps.db = await setDb()
    if (steps.db === "ok") {
      steps.ban = await setBan(true)
      steps.sessions = (await revokeUserSessions(admin, target.id)) ? "ok" : "failed"
    }
  }

  const allOk = active ? steps.ban === "ok" && steps.db === "ok" : steps.db === "ok" && steps.ban === "ok" && steps.sessions === "ok"
  await finishStaffAudit(admin, audit, allOk, { steps, ...counts, partial: !allOk && steps.db === "ok" })

  if (!allOk) {
    if (steps.db === "ok") {
      // the database change is done but the login ban / session revocation is not: tell the master, who can simply retry
      await admin.from("notifications").insert({
        org_id: caller.orgId,
        user_id: caller.userId,
        type: "staff_active_partial",
        title: "A staff change was only partly completed",
        body: `Changing a sales person's access finished in the database but not everywhere (${steps.ban === "failed" ? "login ban" : "session revocation"}). Repeat the action to finish.`,
        ref_id: target.id,
      })
    }
    return json({ ok: false, partial: steps.db === "ok", active: steps.db === "ok" ? active : target.is_active, steps }, steps.db === "ok" ? 200 : 500)
  }

  console.log(`admin-set-staff-active: master ${caller.userId} set ${target.id} active=${active}`)
  return json({ ok: true, active, steps, ...counts })
})
