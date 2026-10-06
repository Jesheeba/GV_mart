import { beforeEach, describe, expect, it, vi } from "vitest"

// Runs the REAL admin-create-staff handler (index.ts) in Node with a fake Deno runtime and a fake service-role
// client, so the request flow is exercised end to end: guard, validation, audit-first, create, rollback, response.

type Row = Record<string, unknown>
type Db = {
  users: Record<string, string> // jwt -> user id
  profiles: Record<string, Row> // id -> profile row
  authUsers: Row[]
  audit: Row[]
  failProfileInsert: boolean
  failAuditInsert: boolean
  failCreateWith: { code?: string; message?: string } | null
  failDeleteUser: boolean
  calls: string[]
}

const db: Db = { users: {}, profiles: {}, authUsers: [], audit: [], failProfileInsert: false, failAuditInsert: false, failCreateWith: null, failDeleteUser: false, calls: [] }
let handler: (req: Request) => Promise<Response>

function client() {
  return {
    auth: {
      getUser: async (token: string) => {
        const id = db.users[token]
        return id ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { message: "bad jwt" } }
      },
      admin: {
        createUser: async (a: { email: string; password: string; email_confirm: boolean }) => {
          db.calls.push("createUser")
          if (db.failCreateWith) return { data: { user: null }, error: db.failCreateWith }
          const user = { id: `new-${db.authUsers.length + 1}`, email: a.email }
          db.authUsers.push({ ...user, email_confirm: a.email_confirm, password: a.password })
          return { data: { user }, error: null }
        },
        deleteUser: async (id: string) => {
          db.calls.push("deleteUser")
          if (db.failDeleteUser) return { error: { message: "nope" } }
          db.authUsers = db.authUsers.filter((u) => u.id !== id)
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
            return p ? { data: p, error: null } : { data: null, error: { message: "not found" } }
          }
          const r = db.audit.find((x) => x.id === filterId)
          return r ? { data: r, error: null } : { data: null, error: { message: "none" } }
        },
        insert: (row: Row) => {
          if (table === "profiles") {
            db.calls.push("insertProfile")
            if (db.failProfileInsert) return Promise.resolve({ error: { message: "insert failed" } })
            db.profiles[String(row.id)] = row
            return Promise.resolve({ error: null })
          }
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
  db.users = { "master-jwt": "u-master", "sales-jwt": "u-sales", "old-master-jwt": "u-oldmaster", "tech-jwt": "u-tech" }
  db.profiles = {
    "u-master": { org_id: "org-1", role: "master", is_active: true },
    "u-sales": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-oldmaster": { org_id: "org-1", role: "master", is_active: false },
    "u-tech": { org_id: "org-1", role: "technician", is_active: true },
  }
  db.authUsers = []
  db.audit = []
  db.failProfileInsert = false
  db.failAuditInsert = false
  db.failCreateWith = null
  db.failDeleteUser = false
  db.calls = []
  ;(globalThis as { Deno?: unknown }).Deno = { env: { get: (k: string) => ENV[k] }, serve: (h: (req: Request) => Promise<Response>) => (handler = h) }
  vi.resetModules()
  await import("../admin-create-staff/index")
})

const call = (body: unknown, token: string | null = "master-jwt", method = "POST") =>
  handler(new Request("https://fn.test/admin-create-staff", { method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: method === "POST" ? JSON.stringify(body) : undefined }))
const good = { fullName: "Priya Dharshini", email: "priya@example.com", role: "sales_admin" }

describe("admin-create-staff handler", () => {
  it("answers CORS preflight and refuses non-POST", async () => {
    expect((await call({}, null, "OPTIONS")).status).toBe(200)
    expect((await call({}, "master-jwt", "GET")).status).toBe(405)
  })

  it("401 without an Authorization header, and for a token that is not a signed-in user (such as the anon key)", async () => {
    expect((await call(good, null)).status).toBe(401)
    expect((await call(good, "anon-key-jwt")).status).toBe(401)
    expect(db.calls).toEqual([])
  })

  it("403 for a sales_admin, a technician and an INACTIVE master; nothing is created or audited", async () => {
    for (const t of ["sales-jwt", "tech-jwt", "old-master-jwt"]) expect((await call(good, t)).status, t).toBe(403)
    expect(db.calls).toEqual([])
    expect(db.audit).toHaveLength(0)
  })

  it("400 for master / technician / customer roles and for bad input, before anything is audited or created", async () => {
    for (const role of ["master", "technician", "customer"]) expect((await call({ ...good, role })).status, role).toBe(400)
    expect((await call({ ...good, email: "nope" })).status).toBe(400)
    expect((await call("not json")).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("creates a sales_admin with a generated password: 200, password shown once, profile in the CALLER's org, audit completed", async () => {
    const res = await call({ ...good, reason: "joins sales team", org_id: "attacker-org", is_active: false })
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toMatchObject({ ok: true, email: "priya@example.com", generated: true })
    expect(typeof body.password).toBe("string")
    expect(body.password).toHaveLength(14)
    expect(db.calls).toEqual(["insertAudit", "createUser", "insertProfile"]) // audit FIRST
    expect(db.profiles[body.id]).toEqual({ id: body.id, org_id: "org-1", full_name: "Priya Dharshini", phone: null, role: "sales_admin", is_active: true })
    expect(db.authUsers[0]).toMatchObject({ email: "priya@example.com", email_confirm: true })
    expect(db.audit).toHaveLength(1)
    expect(db.audit[0]).toMatchObject({ org_id: "org-1", actor_id: "u-master", action: "STAFF_CREATE", table_name: "profiles", row_id: body.id })
    expect(db.audit[0].after).toMatchObject({ result: "ok", role: "sales_admin", email: "priya@example.com", full_name: "Priya Dharshini", generated: true, reason: "joins sales team" })
  })

  it("the password never appears in the audit row, and a typed password is not echoed back", async () => {
    const generated = await (await call(good)).json()
    expect(JSON.stringify(db.audit[0])).not.toContain(generated.password)
    db.audit = []
    const typed = await (await call({ ...good, email: "second@example.com", password: "my typed pass 99" })).json()
    expect(typed).toMatchObject({ ok: true, generated: false })
    expect(typed.password).toBeUndefined()
    expect(JSON.stringify(db.audit[0])).not.toContain("my typed pass 99")
    expect(db.authUsers.at(-1)).toMatchObject({ password: "my typed pass 99" })
  })

  it("creates an operation_admin too", async () => {
    const res = await call({ ...good, role: "operation_admin", email: "ops@example.com", phone: "98765 43210" })
    expect(res.status).toBe(200)
    const { id } = await res.json()
    expect(db.profiles[id]).toMatchObject({ role: "operation_admin", phone: "9876543210" })
  })

  it("409 for a duplicate email (and the audit row says so); a weak-password style error is NOT reported as a duplicate", async () => {
    db.failCreateWith = { code: "email_exists", message: "A user with this email address has already been registered" }
    expect((await call(good)).status).toBe(409)
    expect(db.audit[0].after).toMatchObject({ result: "failed", error: "duplicate_email" })
    db.audit = []
    db.failCreateWith = { code: "weak_password", message: "Password should be at least 6 characters" }
    const res = await call(good)
    expect(res.status).toBe(400)
    expect(db.audit[0].after).toMatchObject({ result: "failed", error: "auth_create_failed" })
    expect(db.profiles["new-1"]).toBeUndefined()
  })

  it("rolls the auth user back when the profile insert fails, and says so in the audit row", async () => {
    db.failProfileInsert = true
    const res = await call(good)
    expect(res.status).toBe(500)
    expect(db.authUsers).toHaveLength(0)
    expect(db.calls).toEqual(["insertAudit", "createUser", "insertProfile", "deleteUser"])
    expect(db.audit[0].after).toMatchObject({ result: "failed", error: "profile_insert_failed", rolled_back: true })
  })

  it("fails closed when the audit row cannot be written: no account is created", async () => {
    db.failAuditInsert = true
    const res = await call(good)
    expect(res.status).toBe(500)
    expect(db.calls).toEqual(["insertAudit"])
    expect(db.authUsers).toHaveLength(0)
  })

  it("never logs the password or the service-role key", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {})
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const body = await (await call(good)).json()
    db.failProfileInsert = true
    await call({ ...good, email: "other@example.com", password: "typed secret 123" })
    const logged = JSON.stringify([...spy.mock.calls, ...errSpy.mock.calls])
    expect(logged).not.toContain(body.password)
    expect(logged).not.toContain("typed secret 123")
    expect(logged).not.toContain("service-role-secret")
    spy.mockRestore()
    errSpy.mockRestore()
  })
})
