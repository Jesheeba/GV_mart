import { describe, expect, it } from "vitest"
import { beginStaffAudit, checkStaffTarget, finishStaffAudit, requireActiveMaster } from "./staff-auth"

// Fake Supabase admin client: auth.getUser plus a tiny in-memory table API (select / insert / update with eq / single).
type Profile = { org_id: string; role: string; is_active: boolean }
type Row = { id: string; [k: string]: unknown }

function fakeAdmin(opts: { users?: Record<string, string>; profiles?: Record<string, Profile>; failAuditInsert?: boolean } = {}) {
  const rows: Row[] = []
  const client = {
    auth: {
      getUser: async (token: string) => {
        const id = opts.users?.[token]
        return id ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { message: "bad jwt" } }
      },
    },
    from(table: string) {
      let filterId: string | null = null
      const api = {
        select: () => api,
        eq: (_c: string, v: string) => {
          filterId = v
          return api
        },
        single: async () => {
          if (table === "profiles") {
            const p = filterId ? opts.profiles?.[filterId] : undefined
            return p ? { data: p, error: null } : { data: null, error: { message: "not found" } }
          }
          const r = rows.find((x) => x.id === filterId) ?? rows[rows.length - 1]
          return r ? { data: r, error: null } : { data: null, error: { message: "none" } }
        },
        insert: (row: Record<string, unknown>) => {
          if (opts.failAuditInsert) return { select: () => ({ single: async () => ({ data: null, error: { message: "denied" } }) }) }
          const stored: Row = { id: `audit-${rows.length + 1}`, ...row }
          rows.push(stored)
          return { select: () => ({ single: async () => ({ data: { id: stored.id }, error: null }) }) }
        },
        update: (patch: Record<string, unknown>) => ({
          eq: async (_c: string, v: string) => {
            const r = rows.find((x) => x.id === v)
            if (r) Object.assign(r, patch)
            return { error: null }
          },
        }),
      }
      return api
    },
  }
  return { client: client as never, rows }
}

const master: Profile = { org_id: "org-1", role: "master", is_active: true }

describe("requireActiveMaster", () => {
  const users = { "good-token": "u-master", "sales-token": "u-sales", "inactive-token": "u-old", "ghost-token": "u-ghost" }
  const profiles = {
    "u-master": master,
    "u-sales": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-old": { org_id: "org-1", role: "master", is_active: false },
  }

  it("rejects a missing Authorization header (401)", async () => {
    expect(await requireActiveMaster(fakeAdmin({ users, profiles }).client, null)).toEqual({ ok: false, status: 401, error: "Missing Authorization header" })
  })
  it("rejects a token that is not a signed-in user, such as the anon key (401)", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer anon-key-not-a-user")
    expect(r.ok === false && r.status).toBe(401)
  })
  it("rejects a valid user that has no profile (403)", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer ghost-token")
    expect(r.ok === false && r.status).toBe(403)
  })
  it("rejects a non-master (403)", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer sales-token")
    expect(r.ok === false && r.status).toBe(403)
  })
  it("rejects an INACTIVE master (403)", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer inactive-token")
    expect(r.ok === false && r.status).toBe(403)
  })
  it("accepts an active master and returns the caller and organisation", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer good-token")
    expect(r).toEqual({ ok: true, caller: { userId: "u-master", orgId: "org-1" } })
  })
})

describe("checkStaffTarget", () => {
  const caller = { userId: "u-master", orgId: "org-1" }
  it("allows operation_admin and sales_admin in the same organisation", () => {
    expect(checkStaffTarget(caller, { id: "t", org_id: "org-1", role: "sales_admin" }).ok).toBe(true)
    expect(checkStaffTarget(caller, { id: "t", org_id: "org-1", role: "operation_admin" }).ok).toBe(true)
  })
  it("refuses ANY master target (403), including the caller themselves", () => {
    const self = checkStaffTarget(caller, { id: "u-master", org_id: "org-1", role: "master" })
    expect(self.ok === false && self.status).toBe(403)
    const other = checkStaffTarget(caller, { id: "m2", org_id: "org-1", role: "master" })
    expect(other.ok === false && other.status).toBe(403)
  })
  it("treats another organisation's staff, and unknown ids, as not found (404)", () => {
    expect(checkStaffTarget(caller, { id: "t", org_id: "org-2", role: "sales_admin" })).toMatchObject({ ok: false, status: 404 })
    expect(checkStaffTarget(caller, null)).toMatchObject({ ok: false, status: 404 })
  })
  it("refuses technicians and customers (400)", () => {
    expect(checkStaffTarget(caller, { id: "t", org_id: "org-1", role: "technician" })).toMatchObject({ ok: false, status: 400 })
    expect(checkStaffTarget(caller, { id: "t", org_id: "org-1", role: "customer" })).toMatchObject({ ok: false, status: 400 })
  })
})

describe("staff audit rows", () => {
  it("writes the row first, then completes it with the outcome, and never holds a password", async () => {
    const f = fakeAdmin()
    const id = await beginStaffAudit(f.client, { orgId: "org-1", actorId: "u-master", action: "STAFF_PASSWORD_RESET", targetId: "t", details: { target_role: "sales_admin", generated: true } })
    expect(id).toBe("audit-1")
    expect(f.rows[0]).toMatchObject({ org_id: "org-1", actor_id: "u-master", action: "STAFF_PASSWORD_RESET", table_name: "profiles", row_id: "t", after: { result: "pending", generated: true } })
    await finishStaffAudit(f.client, id!, true)
    expect(f.rows[0].after).toMatchObject({ result: "ok", target_role: "sales_admin" })
    expect(JSON.stringify(f.rows[0])).not.toMatch(/password"\s*:/i)
  })
  it("records a failed outcome", async () => {
    const f = fakeAdmin()
    const id = await beginStaffAudit(f.client, { orgId: "org-1", actorId: "u", action: "STAFF_PASSWORD_RESET", targetId: "t", details: {} })
    await finishStaffAudit(f.client, id!, false, { error: "update failed" })
    expect(f.rows[0].after).toMatchObject({ result: "failed", error: "update failed" })
  })
  it("returns null when the audit row cannot be written, so the caller can refuse the action", async () => {
    const f = fakeAdmin({ failAuditInsert: true })
    expect(await beginStaffAudit(f.client, { orgId: "o", actorId: "u", action: "STAFF_PASSWORD_RESET", targetId: "t", details: {} })).toBeNull()
  })
})
