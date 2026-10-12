import { beforeEach, describe, expect, it, vi } from "vitest"

// Runs the REAL admin-set-staff-active handler (index.ts) in Node with a fake Deno runtime and a fake service-role
// client: guard, target rules, audit pair, step ORDER (deactivate: db, ban, sessions; reactivate: unban, db),
// partial outcomes, idempotency, CORS, fixed messages.

type Row = Record<string, unknown>
const db = {
  users: {} as Record<string, string>,
  profiles: {} as Record<string, Row>,
  audit: [] as Row[],
  notifications: [] as Row[],
  calls: [] as string[],
  bans: [] as Array<{ id: string; ban: string }>,
  failAuditInsert: false,
  failRpc: false,
  failBan: false,
  failRevoke: false,
  rpcResult: { changed: true, leads_unassigned: 3, followups_to_master: 2, tasks_to_master: 4, leads_waiting: 3 } as Row,
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
        updateUserById: async (id: string, a: { ban_duration: string }) => {
          db.calls.push(`ban:${a.ban_duration === "none" ? "off" : "on"}`)
          if (db.failBan) return { error: { code: "unexpected_failure", message: "x" } }
          db.bans.push({ id, ban: a.ban_duration })
          return { error: null }
        },
      },
    },
    rpc: async (fn: string, args: Row) => {
      db.calls.push(`rpc:${fn}`)
      if (fn === "set_sales_person_active") {
        if (db.failRpc) return { data: null, error: { code: "P0001", message: "boom" } }
        return { data: db.rpcResult, error: null }
      }
      if (fn === "revoke_user_sessions") {
        if (db.failRevoke) return { data: null, error: { code: "42501", message: "denied" } }
        return { data: 1, error: null, args }
      }
      return { data: null, error: { message: "unknown rpc" } }
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
          if (table === "notifications") {
            db.notifications.push({ ...row })
            return { error: null }
          }
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
const ENV: Record<string, string> = { SUPABASE_URL: "https://x.supabase.co", SUPABASE_SERVICE_ROLE_KEY: "service-role-secret", ALLOWED_ORIGINS: "https://app.example.test" }

beforeEach(async () => {
  db.users = { "master-jwt": "u-master", "sales-jwt": "u-sales", "old-master-jwt": "u-oldmaster" }
  db.profiles = {
    "u-master": { org_id: "org-1", role: "master", is_active: true, full_name: "Ramesh Kumar" },
    "u-oldmaster": { org_id: "org-1", role: "master", is_active: false },
    "u-sales": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-sales2": { org_id: "org-1", role: "sales_admin", is_active: true },
    "u-sales-off": { org_id: "org-1", role: "sales_admin", is_active: false },
    "u-ops": { org_id: "org-1", role: "operation_admin", is_active: true },
    "u-master2": { org_id: "org-1", role: "master", is_active: true },
    "u-tech": { org_id: "org-1", role: "technician", is_active: true },
    "u-foreign": { org_id: "org-2", role: "sales_admin", is_active: true },
  }
  db.audit = []
  db.notifications = []
  db.calls = []
  db.bans = []
  db.failAuditInsert = false
  db.failRpc = false
  db.failBan = false
  db.failRevoke = false
  ;(globalThis as { Deno?: unknown }).Deno = { env: { get: (k: string) => ENV[k] }, serve: (h: (req: Request) => Promise<Response>) => (handler = h) }
  vi.resetModules()
  await import("../admin-set-staff-active/index")
})

const call = (body: unknown, token: string | null = "master-jwt", origin?: string) =>
  handler(
    new Request("https://fn.test/admin-set-staff-active", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(origin ? { Origin: origin } : {}) },
      body: JSON.stringify(body),
    })
  )
const startRow = () => db.audit.find((r) => (r.after as Row).phase === "start")!
const resultRow = () => db.audit.find((r) => (r.after as Row).phase === "result")!

describe("admin-set-staff-active handler", () => {
  it("401 without a usable token; 403 for a non-master and for an INACTIVE master; nothing happens", async () => {
    expect((await call({ profileId: "u-sales", active: false }, null)).status).toBe(401)
    expect((await call({ profileId: "u-sales", active: false }, "anon-key")).status).toBe(401)
    expect((await call({ profileId: "u-ops", active: false }, "sales-jwt")).status).toBe(403)
    expect((await call({ profileId: "u-sales", active: false }, "old-master-jwt")).status).toBe(403)
    expect(db.calls).toEqual([])
  })

  it("refuses a master target (403, including the caller), other organisations (404), technicians and operation_admins (400)", async () => {
    expect((await call({ profileId: "u-master2", active: false })).status).toBe(403)
    expect((await call({ profileId: "u-master", active: false })).status).toBe(403)
    expect((await call({ profileId: "u-foreign", active: false })).status).toBe(404)
    expect((await call({ profileId: "nobody", active: false })).status).toBe(404)
    expect((await call({ profileId: "u-tech", active: false })).status).toBe(400)
    expect((await call({ profileId: "u-ops", active: false })).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("400 for a bad body: non-string profileId, non-boolean active", async () => {
    expect((await call({ profileId: { $ne: 1 }, active: false })).status).toBe(400)
    expect((await call({ profileId: "u-sales", active: "false" })).status).toBe(400)
    expect((await call({ profileId: "u-sales" })).status).toBe(400)
    expect(db.calls).toEqual([])
  })

  it("deactivation runs in order: audit start, database, ban, sessions, audit result; reports the counts", async () => {
    const res = await call({ profileId: "u-sales", active: false, reason: "left the company" })
    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json).toMatchObject({ ok: true, active: false, steps: { db: "ok", ban: "ok", sessions: "ok" }, leads_unassigned: 3, followups_to_master: 2, tasks_to_master: 4 })
    expect(db.calls).toEqual(["insertAudit", "rpc:set_sales_person_active", "ban:on", "rpc:revoke_user_sessions", "insertAudit"])
    expect(db.bans).toEqual([{ id: "u-sales", ban: "876000h" }])
    expect(db.audit).toHaveLength(2)
    expect(startRow().action).toBe("STAFF_DEACTIVATE")
    expect((startRow().after as Row).reason).toBe("left the company")
    expect((startRow().after as Row).actor_name).toBe("Ramesh Kumar")
    expect((startRow().after as Row).correlation_id).toBe((resultRow().after as Row).correlation_id)
    expect((resultRow().after as Row).result).toBe("ok")
  })

  it("reactivation runs in the opposite order: unban first, then the database; no session revocation", async () => {
    const res = await call({ profileId: "u-sales-off", active: true })
    expect(res.status).toBe(200)
    expect(db.calls).toEqual(["insertAudit", "ban:off", "rpc:set_sales_person_active", "insertAudit"])
    expect(startRow().action).toBe("STAFF_REACTIVATE")
    expect((await res.json()).steps).toEqual({ db: "ok", ban: "ok", sessions: "skipped" })
  })

  it("reactivation: if the unban fails the database is NOT touched (no access granted)", async () => {
    db.failBan = true
    const res = await call({ profileId: "u-sales-off", active: true })
    expect(res.status).toBe(500)
    expect(db.calls).not.toContain("rpc:set_sales_person_active")
    expect((await res.json()).steps).toMatchObject({ ban: "failed", db: "skipped" })
    expect((resultRow().after as Row).result).toBe("failed")
  })

  it("deactivation: the database step failing stops everything (nothing banned), 500, audited as failed", async () => {
    db.failRpc = true
    const res = await call({ profileId: "u-sales", active: false })
    expect(res.status).toBe(500)
    expect(db.calls).toEqual(["insertAudit", "rpc:set_sales_person_active", "insertAudit"])
    expect(db.bans).toEqual([])
    expect((resultRow().after as Row).result).toBe("failed")
    expect(db.notifications).toHaveLength(0)
  })

  it("deactivation: ban failing after the database step is a PARTIAL (200, ok:false, partial:true) with a notification to the master; retry is safe", async () => {
    db.failBan = true
    const res = await call({ profileId: "u-sales", active: false })
    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json).toMatchObject({ ok: false, partial: true, active: false, steps: { db: "ok", ban: "failed", sessions: "ok" } })
    expect((resultRow().after as Row).partial).toBe(true)
    expect(db.notifications).toHaveLength(1)
    expect(db.notifications[0]).toMatchObject({ type: "staff_active_partial", user_id: "u-master", ref_id: "u-sales" })
  })

  it("deactivation: session revocation failing is a PARTIAL too", async () => {
    db.failRevoke = true
    const json = await (await call({ profileId: "u-sales", active: false })).json()
    expect(json).toMatchObject({ ok: false, partial: true, steps: { db: "ok", ban: "ok", sessions: "failed" } })
  })

  it("fails closed when the audit start row cannot be written: nothing is changed", async () => {
    db.failAuditInsert = true
    const res = await call({ profileId: "u-sales", active: false })
    expect(res.status).toBe(500)
    expect(db.calls).toEqual(["insertAudit"])
    expect(db.bans).toEqual([])
  })

  it("never forwards internal error text", async () => {
    db.failRpc = true
    const text = JSON.stringify(await (await call({ profileId: "u-sales", active: false })).json())
    expect(text).not.toContain("boom")
    expect(text).not.toContain("P0001")
  })

  it("CORS answers only the configured origin", async () => {
    const ok = await call({ profileId: "u-sales", active: false }, "master-jwt", "https://app.example.test")
    expect(ok.headers.get("Access-Control-Allow-Origin")).toBe("https://app.example.test")
    const evil = await call({ profileId: "u-sales2", active: false }, "master-jwt", "https://evil.example")
    expect(evil.headers.get("Access-Control-Allow-Origin")).toBeNull()
  })
})
