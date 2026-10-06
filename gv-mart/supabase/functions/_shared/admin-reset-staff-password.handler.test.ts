import { beforeEach, describe, expect, it, vi } from "vitest"

// Runs the REAL admin-reset-staff-password handler (index.ts, as hardened in 2fb0417) in Node with a fake Deno
// runtime and a fake service-role client.

type Row = Record<string, unknown>
const db = {
  users: {} as Record<string, string>,
  profiles: {} as Record<string, Row>,
  audit: [] as Row[],
  passwords: {} as Record<string, string>,
  failAuditInsert: false,
  failUpdate: false,
  calls: [] as string[],
}
let handler: (req: Request) => Promise<Response>

function client() {
  return {
    auth: {
      getUser: async (token: string) => {
        const id = db.users[token]
        return id ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { message: "bad jwt" } }
      },
      admin: {
        updateUserById: async (id: string, a: { password: string }) => {
          db.calls.push("updateUser")
          if (db.failUpdate) return { error: { message: "update failed" } }
          db.passwords[id] = a.password
          return { error: null }
        },
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
            const p = filterId ? db.profiles[filterId] : undefined
            return p ? { data: { id: filterId, ...p }, error: null } : { data: null, error: { message: "not found" } }
          }
          const r = db.audit.find((x) => x.id === filterId)
          return r ? { data: r, error: null } : { data: null, error: { message: "none" } }
        },
        insert: (row: Row) => {
          db.calls.push("insertAudit")
          if (db.failAuditInsert) return { select: () => ({ single: async () => ({ data: null, error: { message: "denied" } }) }) }
          const stored = { id: `audit-${db.audit.length + 1}`, ...row }
          db.audit.push(stored)
          return { select: () => ({ single: async () => ({ data: { id: stored.id }, error: null }) }) }
        },
        update: (patch: Row) => ({
          eq: async (_c: string, v: string) => {
            const r = db.audit.find((x) => x.id === v)
            if (r) Object.assign(r, patch)
            return { error: null }
          },
        }),
      }
      return api
    },
  }
}

vi.mock("jsr:@supabase/supabase-js@2", () => ({ createClient: () => client() }))
const ENV: Record<string, string> = { SUPABASE_URL: "https://x.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "service-role-secret" }

beforeEach(async () => {
  db.users = { "master-jwt": "u-master", "sales-jwt": "u-sales", "old-master-jwt": "u-oldmaster" }
  db.profiles = {
    "u-master": { org_id: "org-1", role: "master", is_active: true },
    "u-oldmaster": { org_id: "org-1", role: "master", is_active: false },
    "u-sales": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-ops": { org_id: "org-1", role: "operation_admin", is_active: true },
    "u-master2": { org_id: "org-1", role: "master", is_active: true },
    "u-tech": { org_id: "org-1", role: "technician", is_active: true },
    "u-foreign": { org_id: "org-2", role: "sales_admin", is_active: true },
  }
  db.audit = []
  db.passwords = {}
  db.failAuditInsert = false
  db.failUpdate = false
  db.calls = []
  ;(globalThis as { Deno?: unknown }).Deno = { env: { get: (k: string) => ENV[k] }, serve: (h: (req: Request) => Promise<Response>) => (handler = h) }
  vi.resetModules()
  await import("../admin-reset-staff-password/index")
})

const call = (body: unknown, token: string | null = "master-jwt") =>
  handler(new Request("https://fn.test/admin-reset-staff-password", { method: "POST", headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) }))

describe("admin-reset-staff-password handler (hardened)", () => {
  it("401 without a header or with a token that is not a signed-in user", async () => {
    expect((await call({ profileId: "u-sales" }, null)).status).toBe(401)
    expect((await call({ profileId: "u-sales" }, "anon-key")).status).toBe(401)
    expect(db.calls).toEqual([])
  })

  it("403 for a non-master and for an INACTIVE master", async () => {
    expect((await call({ profileId: "u-ops", password: "longenough1" }, "sales-jwt")).status).toBe(403)
    expect((await call({ profileId: "u-ops", password: "longenough1" }, "old-master-jwt")).status).toBe(403)
    expect(db.calls).toEqual([])
  })

  it("refuses ANY master target (403): another master AND the caller themselves; nothing audited or changed", async () => {
    expect((await call({ profileId: "u-master2", password: "longenough1" })).status).toBe(403)
    expect((await call({ profileId: "u-master", password: "longenough1" })).status).toBe(403)
    expect(db.calls).toEqual([])
    expect(db.passwords).toEqual({})
  })

  it("404 for another organisation's staff or an unknown id; 400 for a technician", async () => {
    expect((await call({ profileId: "u-foreign", password: "longenough1" })).status).toBe(404)
    expect((await call({ profileId: "nobody", password: "longenough1" })).status).toBe(404)
    expect((await call({ profileId: "u-tech", password: "longenough1" })).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("resets a sales_admin with a typed password: audit written FIRST, completed ok, password not echoed or audited", async () => {
    const res = await call({ profileId: "u-sales", password: "typed password 42" })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true, generated: false })
    expect(db.calls).toEqual(["insertAudit", "updateUser"])
    expect(db.passwords["u-sales"]).toBe("typed password 42")
    expect(db.audit[0]).toMatchObject({ org_id: "org-1", actor_id: "u-master", action: "STAFF_PASSWORD_RESET", table_name: "profiles", row_id: "u-sales" })
    expect(db.audit[0].after).toMatchObject({ result: "ok", target_role: "sales_admin", generated: false })
    expect(JSON.stringify(db.audit[0])).not.toContain("typed password 42")
  })

  it("generates a password for an operation_admin when none is typed, returns it once, and keeps it out of the audit row", async () => {
    const res = await call({ profileId: "u-ops" })
    const body = await res.json()
    expect(res.status).toBe(200)
    expect(body).toMatchObject({ ok: true, generated: true })
    expect(body.password).toHaveLength(14)
    expect(db.passwords["u-ops"]).toBe(body.password)
    expect(JSON.stringify(db.audit[0])).not.toContain(body.password)
  })

  it("rejects a typed password outside 8-72 characters before touching anything", async () => {
    expect((await call({ profileId: "u-sales", password: "short" })).status).toBe(400)
    expect((await call({ profileId: "u-sales", password: "x".repeat(73) })).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("fails closed when the audit row cannot be written: the password is NOT changed", async () => {
    db.failAuditInsert = true
    const res = await call({ profileId: "u-sales", password: "longenough1" })
    expect(res.status).toBe(500)
    expect(db.calls).toEqual(["insertAudit"])
    expect(db.passwords).toEqual({})
  })

  it("records a failed outcome when Auth refuses the update", async () => {
    db.failUpdate = true
    const res = await call({ profileId: "u-sales", password: "longenough1" })
    expect(res.status).toBe(400)
    expect(db.audit[0].after).toMatchObject({ result: "failed", error: "update failed" })
  })

  it("never logs the password or the service-role key", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {})
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const generated = await (await call({ profileId: "u-ops" })).json()
    await call({ profileId: "u-sales", password: "typed secret 777" })
    const logged = JSON.stringify([...spy.mock.calls, ...errSpy.mock.calls])
    expect(logged).not.toContain(generated.password)
    expect(logged).not.toContain("typed secret 777")
    expect(logged).not.toContain("service-role-secret")
    spy.mockRestore()
    errSpy.mockRestore()
  })
})
