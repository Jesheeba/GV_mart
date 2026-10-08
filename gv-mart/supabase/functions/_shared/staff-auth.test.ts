import { describe, expect, it, vi } from "vitest"
import {
  beginStaffAudit,
  checkStaffTarget,
  classifyAuthError,
  finishStaffAudit,
  generatePassword,
  requireActiveMaster,
  revokeUserSessions,
  validateCreateStaffInput,
  validateTypedPassword,
} from "./staff-auth"
import { staffCorsHeaders, staffPreflight } from "./staff-cors"

// Fake Supabase admin client: auth.getUser, an in-memory table API (select / eq / single / insert only: audit is
// append-only, so there is deliberately NO update) and rpc.
type Profile = { org_id: string; role: string; is_active: boolean; full_name?: string }
type Row = Record<string, unknown>

function fakeAdmin(opts: { users?: Record<string, string>; profiles?: Record<string, Profile>; failAuditInsert?: boolean; failRpc?: boolean } = {}) {
  const rows: Row[] = []
  const rpcCalls: { fn: string; args: unknown }[] = []
  const client = {
    auth: {
      getUser: async (token: string) => {
        const id = opts.users?.[token]
        return id ? { data: { user: { id } }, error: null } : { data: { user: null }, error: { message: "bad jwt" } }
      },
    },
    rpc: async (fn: string, args: unknown) => {
      rpcCalls.push({ fn, args })
      return opts.failRpc ? { data: null, error: { code: "42501", message: "denied" } } : { data: 1, error: null }
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
          const p = table === "profiles" && filterId ? opts.profiles?.[filterId] : undefined
          return p ? { data: p, error: null } : { data: null, error: { message: "not found" } }
        },
        insert: async (row: Row) => {
          if (opts.failAuditInsert) return { error: { message: "denied" } }
          rows.push({ ...row })
          return { error: null }
        },
      }
      return api
    },
  }
  return { client: client as never, rows, rpcCalls }
}

const master: Profile = { org_id: "org-1", role: "master", is_active: true, full_name: "Ramesh Kumar" }
const caller = { userId: "u-master", orgId: "org-1", fullName: "Ramesh Kumar" }

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
  it("accepts an active master and returns the caller, organisation and name (for the audit snapshot)", async () => {
    const r = await requireActiveMaster(fakeAdmin({ users, profiles }).client, "Bearer good-token")
    expect(r).toEqual({ ok: true, caller: { userId: "u-master", orgId: "org-1", fullName: "Ramesh Kumar" } })
  })
})

describe("checkStaffTarget", () => {
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

describe("staff audit rows (append-only: a start row and a separate completion row)", () => {
  it("inserts a start row first and a SEPARATE completion row linked by correlation_id; nothing is updated; no password", async () => {
    const f = fakeAdmin()
    const audit = await beginStaffAudit(f.client, { caller, action: "STAFF_PASSWORD_RESET", targetId: "t", details: { target_role: "sales_admin", generated: true } })
    expect(audit).not.toBeNull()
    expect(f.rows).toHaveLength(1)
    expect(f.rows[0]).toMatchObject({ org_id: "org-1", actor_id: "u-master", action: "STAFF_PASSWORD_RESET", table_name: "profiles", row_id: "t" })
    expect(f.rows[0].after).toMatchObject({ phase: "start", result: "pending", actor_name: "Ramesh Kumar", generated: true })
    expect(await finishStaffAudit(f.client, audit!, true, { sessions_revoked: true })).toBe(true)
    expect(f.rows).toHaveLength(2) // a second row; the first is untouched
    expect(f.rows[0].after).toMatchObject({ phase: "start", result: "pending" })
    expect(f.rows[1].after).toMatchObject({ phase: "result", result: "ok", actor_name: "Ramesh Kumar", sessions_revoked: true })
    expect((f.rows[0].after as Row).correlation_id).toBe((f.rows[1].after as Row).correlation_id)
    expect(JSON.stringify(f.rows)).not.toMatch(/password"\s*:/i)
  })
  it("records a failed outcome", async () => {
    const f = fakeAdmin()
    const audit = await beginStaffAudit(f.client, { caller, action: "STAFF_PASSWORD_RESET", targetId: "t", details: {} })
    await finishStaffAudit(f.client, audit!, false, { error: "update_failed" })
    expect(f.rows[1].after).toMatchObject({ phase: "result", result: "failed", error: "update_failed" })
  })
  it("returns null when the start row cannot be written, so the caller can refuse the action", async () => {
    const f = fakeAdmin({ failAuditInsert: true })
    expect(await beginStaffAudit(f.client, { caller, action: "STAFF_PASSWORD_RESET", targetId: "t", details: {} })).toBeNull()
  })
  it("reports (does not throw) when the completion row cannot be written", async () => {
    const f = fakeAdmin()
    const audit = await beginStaffAudit(f.client, { caller, action: "STAFF_CREATE", targetId: null, details: {} })
    const failing = fakeAdmin({ failAuditInsert: true })
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    expect(await finishStaffAudit(failing.client, audit!, true)).toBe(false)
    spy.mockRestore()
  })
  it("sets row_id to the created user's id on the completion row", async () => {
    const f = fakeAdmin()
    const audit = await beginStaffAudit(f.client, { caller, action: "STAFF_CREATE", targetId: null, details: { role: "sales_admin", email: "a@b.co" } })
    expect(f.rows[0].row_id).toBeNull()
    await finishStaffAudit(f.client, audit!, true, {}, "new-user-id")
    expect(f.rows[1]).toMatchObject({ row_id: "new-user-id", after: { result: "ok" } })
  })
})

describe("classifyAuthError (fixed messages only)", () => {
  it("recognises a duplicate email by code or message, and a weak password separately", () => {
    expect(classifyAuthError({ code: "email_exists" })).toBe("duplicate_email")
    expect(classifyAuthError({ message: "A user with this email address has already been registered" })).toBe("duplicate_email")
    expect(classifyAuthError({ code: "weak_password", message: "Password should be at least 6 characters" })).toBe("weak_password")
    expect(classifyAuthError({ message: "something else" })).toBe("other")
    expect(classifyAuthError(null)).toBe("other")
  })
})

describe("revokeUserSessions", () => {
  it("calls the service-role-only revoke_user_sessions function with the target's id", async () => {
    const f = fakeAdmin()
    expect(await revokeUserSessions(f.client, "u-sales")).toBe(true)
    expect(f.rpcCalls).toEqual([{ fn: "revoke_user_sessions", args: { p_user_id: "u-sales" } }])
  })
  it("returns false (and logs only the user id and code) when the function fails", async () => {
    const f = fakeAdmin({ failRpc: true })
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    expect(await revokeUserSessions(f.client, "u-sales")).toBe(false)
    expect(JSON.stringify(spy.mock.calls)).not.toContain("denied")
    spy.mockRestore()
  })
})

describe("validateTypedPassword (bytes, deny-list)", () => {
  it("accepts a reasonable password", () => {
    expect(validateTypedPassword("correct horse battery")).toBeNull()
    expect(validateTypedPassword("T7!rn-Qv92x")).toBeNull()
  })
  it("counts BYTES, not characters", () => {
    expect(validateTypedPassword("éèêë")).not.toBeNull() // 4 characters = 8 bytes: too short
    expect(validateTypedPassword("éèêëà")).toBeNull() // 5 characters = 10 bytes: long enough
    expect(validateTypedPassword("éèêë".repeat(9))).toBeNull() // 72 bytes exactly
    expect(validateTypedPassword("éèêë".repeat(9) + "x")).not.toBeNull() // 73 bytes
    expect(validateTypedPassword("éèêë".repeat(10))).not.toBeNull() // 40 characters are 80 bytes: over the 72-byte limit even though only 40 characters
  })
  it("rejects fewer than 10 bytes and more than 72 bytes; accepts exactly 10 and exactly 72 ASCII", () => {
    expect(validateTypedPassword("a1!aB2@cD")).not.toBeNull() // 9 bytes
    expect(validateTypedPassword("a1!aB2@cD3")).toBeNull() // 10 bytes
    expect(validateTypedPassword("Zx9!".repeat(18))).toBeNull() // 72 bytes
    expect(validateTypedPassword("Zx9!".repeat(18) + "k")).not.toBeNull() // 73 bytes
  })
  it("rejects common and predictable passwords, case-insensitively", () => {
    for (const p of ["Password123", "PASSWORD1234", "1234567890", "qwertyuiop", "Welcome@123", "gvmart@123", "aaaaaaaaaaaa", "abcdefghijk", "9876543210", "Qwerty12345"]) {
      expect(validateTypedPassword(p), p).not.toBeNull()
    }
  })
  it("rejects non-strings", () => {
    for (const p of [undefined, null, 12345678901, {}, []]) expect(validateTypedPassword(p as never)).not.toBeNull()
  })
})

describe("validateCreateStaffInput", () => {
  const good = { fullName: "  Priya Dharshini ", email: " Priya@Example.COM ", role: "sales_admin" }

  it("accepts the minimum (name, email, role) and normalises it", () => {
    const r = validateCreateStaffInput(good)
    expect(r).toEqual({ ok: true, value: { fullName: "Priya Dharshini", email: "priya@example.com", phone: null, role: "sales_admin", password: null, reason: null } })
  })
  it("accepts operation_admin, a phone in common formats, a typed password and a reason", () => {
    const r = validateCreateStaffInput({ ...good, role: "operation_admin", phone: "+91 98765-43210", password: "correct horse", reason: "covers Coimbatore" })
    expect(r).toMatchObject({ ok: true, value: { role: "operation_admin", phone: "9876543210", password: "correct horse", reason: "covers Coimbatore" } })
  })
  it("NEVER accepts master, technician, customer or anything else as the role", () => {
    for (const role of ["master", "technician", "customer", "admin", "", undefined, null, 5, "Sales_Admin", "sales_admin "]) {
      expect(validateCreateStaffInput({ ...good, role }).ok, String(role)).toBe(false)
    }
  })
  it("ignores fields the client must not control (org, id, is_active)", () => {
    const r = validateCreateStaffInput({ ...good, org_id: "other-org", id: "x", is_active: false, orgId: "other-org" })
    expect(r.ok).toBe(true)
    if (r.ok) expect(Object.keys(r.value).sort()).toEqual(["email", "fullName", "password", "phone", "reason", "role"])
  })
  it("requires a valid email", () => {
    for (const email of ["", "no-at-sign", "a@b", "a b@c.com", undefined, 12, "x".repeat(250) + "@a.co"]) {
      expect(validateCreateStaffInput({ ...good, email }).ok, String(email)).toBe(false)
    }
  })
  it("rejects bad names, phones, passwords and reasons", () => {
    expect(validateCreateStaffInput({ ...good, fullName: "A" }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, fullName: "x".repeat(81) }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, fullName: "Line\nBreak" }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, phone: "12345" }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, password: "short" }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, password: "12345678" }).ok).toBe(false) // under 10 bytes
    expect(validateCreateStaffInput({ ...good, password: "password1234" }).ok).toBe(false) // deny-list
    expect(validateCreateStaffInput({ ...good, password: "Zx9!".repeat(19) }).ok).toBe(false) // over 72 bytes
    expect(validateCreateStaffInput({ ...good, reason: "two\nlines" }).ok).toBe(false)
    expect(validateCreateStaffInput({ ...good, reason: "x".repeat(201) }).ok).toBe(false)
    expect(validateCreateStaffInput(null).ok).toBe(false)
    expect(validateCreateStaffInput("a string").ok).toBe(false)
  })
})

describe("generatePassword", () => {
  it("makes 14-character passwords with every character class, and different each time", () => {
    const seen = new Set<string>()
    for (let i = 0; i < 50; i++) {
      const p = generatePassword()
      expect(p).toHaveLength(14)
      expect(p).toMatch(/[a-z]/)
      expect(p).toMatch(/[A-Z]/)
      expect(p).toMatch(/[2-9]/)
      expect(p).toMatch(/[!@#$%*?]/)
      seen.add(p)
    }
    expect(seen.size).toBe(50)
  })
})

describe("staffCorsHeaders (F-14: origin allow-list read from ALLOWED_ORIGINS)", () => {
  const withEnv = (value: string | undefined, run: () => void) => {
    ;(globalThis as { Deno?: unknown }).Deno = { env: { get: (k: string) => (k === "ALLOWED_ORIGINS" ? value : undefined) } }
    run()
  }
  const req = (origin?: string, method = "POST") => new Request("https://fn.test/x", { method, headers: origin ? { Origin: origin } : {} })

  it("echoes only an exactly listed origin, never '*'", () => {
    withEnv("https://app.example.test, capacitor://localhost", () => {
      expect(staffCorsHeaders(req("https://app.example.test"))["Access-Control-Allow-Origin"]).toBe("https://app.example.test")
      expect(staffCorsHeaders(req("capacitor://localhost"))["Access-Control-Allow-Origin"]).toBe("capacitor://localhost")
      expect(staffCorsHeaders(req("https://evil.example"))["Access-Control-Allow-Origin"]).toBeUndefined()
      expect(staffCorsHeaders(req("https://app.example.test.evil.example"))["Access-Control-Allow-Origin"]).toBeUndefined()
      expect(staffCorsHeaders(req())["Access-Control-Allow-Origin"]).toBeUndefined()
      expect(staffCorsHeaders(req("https://app.example.test")).Vary).toBe("Origin")
    })
  })
  it("fails closed: no ALLOWED_ORIGINS means no Allow-Origin header, and a wildcard entry is ignored", () => {
    withEnv(undefined, () => expect(staffCorsHeaders(req("https://app.example.test"))["Access-Control-Allow-Origin"]).toBeUndefined())
    withEnv("*", () => expect(staffCorsHeaders(req("https://app.example.test"))["Access-Control-Allow-Origin"]).toBeUndefined())
  })
  it("answers preflight with 204 and only POST/OPTIONS allowed", () => {
    withEnv("https://app.example.test", () => {
      const res = staffPreflight(req("https://app.example.test", "OPTIONS"))!
      expect(res.status).toBe(204)
      expect(res.headers.get("Access-Control-Allow-Methods")).toBe("POST, OPTIONS")
      expect(staffPreflight(req("https://app.example.test", "POST"))).toBeNull()
    })
  })
})
