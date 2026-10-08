import { beforeEach, describe, expect, it, vi } from "vitest"

// Runs the REAL admin-reset-staff-password handler (index.ts) in Node with a fake Deno runtime and a fake
// service-role client: CORS, guard, target check, password policy, append-only audit, update, session revocation,
// fixed error messages.

type Row = Record<string, unknown>
const db = {
  users: {} as Record<string, string>,
  profiles: {} as Record<string, Row>,
  audit: [] as Row[],
  passwords: {} as Record<string, string>,
  revoked: [] as string[],
  failAuditInsert: false,
  failUpdateWith: null as { code?: string; message?: string } | null,
  failRevoke: false,
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
          if (db.failUpdateWith) return { error: db.failUpdateWith }
          db.passwords[id] = a.password
          return { error: null }
        },
      },
    },
    rpc: async (fn: string, args: { p_user_id: string }) => {
      db.calls.push(`rpc:${fn}`)
      if (db.failRevoke) return { data: null, error: { code: "42501", message: "denied" } }
      db.revoked.push(args.p_user_id)
      return { data: 1, error: null }
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
          const p = table === "profiles" && filterId ? db.profiles[filterId] : undefined
          return p ? { data: { id: filterId, ...p }, error: null } : { data: null, error: { message: "not found" } }
        },
        insert: async (row: Row) => {
          db.calls.push("insertAudit")
          if (db.failAuditInsert) return { error: { message: "denied" } }
          db.audit.push({ ...row })
          return { error: null }
        },
      }
      return api
    },
  }
}

vi.mock("jsr:@supabase/supabase-js@2", () => ({ createClient: () => client() }))
const ENV: Record<string, string> = {
  SUPABASE_URL: "https://x.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-secret",
  ALLOWED_ORIGINS: "https://app.example.test",
}

beforeEach(async () => {
  db.users = { "master-jwt": "u-master", "sales-jwt": "u-sales", "old-master-jwt": "u-oldmaster" }
  db.profiles = {
    "u-master": { org_id: "org-1", role: "master", is_active: true, full_name: "Ramesh Kumar" },
    "u-oldmaster": { org_id: "org-1", role: "master", is_active: false },
    "u-sales": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-ops": { org_id: "org-1", role: "operation_admin", is_active: true },
    "u-master2": { org_id: "org-1", role: "master", is_active: true },
    "u-tech": { org_id: "org-1", role: "technician", is_active: true },
    "u-foreign": { org_id: "org-2", role: "sales_admin", is_active: true },
  }
  db.audit = []
  db.passwords = {}
  db.revoked = []
  db.failAuditInsert = false
  db.failUpdateWith = null
  db.failRevoke = false
  db.calls = []
  ;(globalThis as { Deno?: unknown }).Deno = { env: { get: (k: string) => ENV[k] }, serve: (h: (req: Request) => Promise<Response>) => (handler = h) }
  vi.resetModules()
  await import("../admin-reset-staff-password/index")
})

const call = (body: unknown, token: string | null = "master-jwt", origin?: string) =>
  handler(
    new Request("https://fn.test/admin-reset-staff-password", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(origin ? { Origin: origin } : {}) },
      body: JSON.stringify(body),
    })
  )
const GOOD_PW = "longenough1xQ"
const startRow = () => db.audit.find((r) => (r.after as Row).phase === "start")!
const resultRow = () => db.audit.find((r) => (r.after as Row).phase === "result")!

describe("admin-reset-staff-password handler (hardened)", () => {
  it("401 without a header or with a token that is not a signed-in user", async () => {
    expect((await call({ profileId: "u-sales" }, null)).status).toBe(401)
    expect((await call({ profileId: "u-sales" }, "anon-key")).status).toBe(401)
    expect(db.calls).toEqual([])
  })

  it("403 for a non-master and for an INACTIVE master", async () => {
    expect((await call({ profileId: "u-ops", password: GOOD_PW }, "sales-jwt")).status).toBe(403)
    expect((await call({ profileId: "u-ops", password: GOOD_PW }, "old-master-jwt")).status).toBe(403)
    expect(db.calls).toEqual([])
  })

  it("refuses ANY master target (403): another master AND the caller themselves; nothing audited or changed", async () => {
    expect((await call({ profileId: "u-master2", password: GOOD_PW })).status).toBe(403)
    expect((await call({ profileId: "u-master", password: GOOD_PW })).status).toBe(403)
    expect(db.calls).toEqual([])
    expect(db.passwords).toEqual({})
  })

  it("404 for another organisation's staff or an unknown id; 400 for a technician and for a non-string profileId", async () => {
    expect((await call({ profileId: "u-foreign", password: GOOD_PW })).status).toBe(404)
    expect((await call({ profileId: "nobody", password: GOOD_PW })).status).toBe(404)
    expect((await call({ profileId: "u-tech", password: GOOD_PW })).status).toBe(400)
    expect((await call({ profileId: { $ne: "x" }, password: GOOD_PW })).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("F-14: CORS answers only the configured origin", async () => {
    const ok = await call({ profileId: "u-sales", password: GOOD_PW }, "master-jwt", "https://app.example.test")
    expect(ok.headers.get("Access-Control-Allow-Origin")).toBe("https://app.example.test")
    const evil = await call({ profileId: "u-sales", password: GOOD_PW }, "master-jwt", "https://evil.example")
    expect(evil.headers.get("Access-Control-Allow-Origin")).toBeNull()
  })

  it("resets a sales_admin with a typed password: audit start FIRST, update, sessions revoked, completion row; password not echoed or audited", async () => {
    const res = await call({ profileId: "u-sales", password: "typed phrase 4271" })
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ ok: true, generated: false, sessionsRevoked: true })
    expect(db.calls).toEqual(["insertAudit", "updateUser", "rpc:revoke_user_sessions", "insertAudit"])
    expect(db.passwords["u-sales"]).toBe("typed phrase 4271")
    expect(db.revoked).toEqual(["u-sales"]) // F-01
    expect(db.audit).toHaveLength(2)
    expect(startRow()).toMatchObject({ org_id: "org-1", actor_id: "u-master", action: "STAFF_PASSWORD_RESET", table_name: "profiles", row_id: "u-sales" })
    expect(startRow().after).toMatchObject({ phase: "start", result: "pending", actor_name: "Ramesh Kumar", target_role: "sales_admin", generated: false })
    expect(resultRow().after).toMatchObject({ phase: "result", result: "ok", sessions_revoked: true })
    expect(JSON.stringify(db.audit)).not.toContain("typed phrase 4271")
  })

  it("F-01: if session revocation fails the reset still succeeds but says so, in the response and in the audit completion row", async () => {
    db.failRevoke = true
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    const res = await call({ profileId: "u-sales", password: GOOD_PW })
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ ok: true, sessionsRevoked: false })
    expect(resultRow().after).toMatchObject({ result: "ok", sessions_revoked: false })
    spy.mockRestore()
  })

  it("generates a password for an operation_admin when none is typed, returns it once, and keeps it out of the audit rows", async () => {
    const res = await call({ profileId: "u-ops" })
    const body = await res.json()
    expect(res.status).toBe(200)
    expect(body).toMatchObject({ ok: true, generated: true })
    expect(body.password).toHaveLength(14)
    expect(db.passwords["u-ops"]).toBe(body.password)
    expect(JSON.stringify(db.audit)).not.toContain(body.password)
  })

  it("F-04: rejects a typed password under 10 bytes, over 72 bytes, or on the deny-list, before touching anything", async () => {
    for (const password of ["short", "12345678", "x".repeat(73), "Zx9!".repeat(19), "password1234", "Welcome@123", "qwertyuiop"]) {
      expect((await call({ profileId: "u-sales", password })).status, password).toBe(400)
    }
    expect(db.calls).toEqual([])
  })

  it("fails closed when the audit start row cannot be written: the password is NOT changed", async () => {
    db.failAuditInsert = true
    const res = await call({ profileId: "u-sales", password: GOOD_PW })
    expect(res.status).toBe(500)
    expect(db.calls).toEqual(["insertAudit"])
    expect(db.passwords).toEqual({})
  })

  it("F-15: Auth failures map to fixed messages and never forward GoTrue's text; no sessions are revoked when the update failed", async () => {
    db.failUpdateWith = { code: "unexpected_failure", message: "internal db detail: relation auth.users" }
    const res = await call({ profileId: "u-sales", password: GOOD_PW })
    expect(res.status).toBe(400)
    expect(await res.json()).toEqual({ error: "Could not reset the password" })
    expect(resultRow().after).toMatchObject({ result: "failed", error: "update_failed" })
    expect(db.revoked).toEqual([])
    db.audit = []
    db.failUpdateWith = { code: "weak_password", message: "Password should be at least 6 characters" }
    const weak = await call({ profileId: "u-sales", password: GOOD_PW })
    expect(weak.status).toBe(400)
    expect(JSON.stringify(await weak.json())).not.toContain("at least 6")
    expect(resultRow().after).toMatchObject({ result: "failed", error: "weak_password" })
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
