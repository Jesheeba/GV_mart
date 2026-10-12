import { describe, expect, it, vi } from "vitest"
import { applyStatusEvent, handleWasiWebhook, toNormalized, type DeliveryState, type WebhookStore } from "./wasi-webhook.handler"

const SECRET = "test-secret-not-real"
const FAKE_WAMID = "wamid.SYNTHETICxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

async function sign(raw: string, secret = SECRET): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw))
  return "sha256=" + Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

function makeStore(over: Partial<WebhookStore> = {}, row?: { id: string } & DeliveryState) {
  const applied: { id: string; patch: Record<string, unknown> }[] = []
  const inbound: unknown[] = []
  const templates: unknown[] = []
  const store: WebhookStore = {
    async findCredentialsByWabaId(w) {
      return w === "waba-1" ? { orgId: "org-1", webhookSecret: SECRET } : null
    },
    async findOutboxByWhatsAppId(id) {
      return id === FAKE_WAMID && row ? { ...row, orgId: "org-1", webhookSecret: SECRET } : null
    },
    async applyDeliveryUpdate(id, patch) {
      applied.push({ id, patch })
    },
    async upsertTemplateStatus(org, name, status) {
      templates.push({ org, name, status })
    },
    async processInbound(org, msg) {
      inbound.push({ org, msg })
    },
    ...over,
  }
  return { store, applied, inbound, templates }
}

function deferCollector() {
  const work: Promise<unknown>[] = []
  return { defer: (p: Promise<unknown>) => void work.push(p), settle: () => Promise.all(work), count: () => work.length }
}

const statusBody = (status: string, extra: Record<string, unknown> = {}) => JSON.stringify({ event: "message.status", data: { message_id: FAKE_WAMID, status, ...extra } })
const row0 = { id: "out-1", delivery_status: "sent", delivered_at: null, read_at: null }

describe("applyStatusEvent", () => {
  const cur = (o: Partial<DeliveryState> = {}): DeliveryState => ({ delivery_status: "sent", delivered_at: null, read_at: null, ...o })
  it("delivered then read move forward and stamp the times", () => {
    expect(applyStatusEvent(cur(), { status: "delivered" }, "N")).toEqual({ delivery_status: "delivered", delivered_at: "N" })
    expect(applyStatusEvent(cur({ delivery_status: "delivered", delivered_at: "D" }), { status: "read" }, "N")).toEqual({ delivery_status: "read", read_at: "N" })
  })
  it("never regresses: read then a late delivered changes nothing", () => {
    expect(applyStatusEvent(cur({ delivery_status: "read", delivered_at: "D", read_at: "R" }), { status: "delivered" }, "N")).toBeNull()
    expect(applyStatusEvent(cur({ delivery_status: "delivered", delivered_at: "D" }), { status: "sent" }, "N")).toBeNull()
  })
  it("read arriving before delivered fills both timestamps", () => {
    const p = applyStatusEvent(cur(), { status: "read" }, "N")
    expect(p).toEqual({ delivery_status: "read", read_at: "N", delivered_at: "N" })
  })
  it("a duplicate delivery of the same event is a no-op", () => {
    expect(applyStatusEvent(cur({ delivery_status: "delivered", delivered_at: "D" }), { status: "delivered" }, "N")).toBeNull()
  })
  it("failed stores Wasi's cleaned error; it is not overridden by a stray failure after delivery", () => {
    const p = applyStatusEvent(cur(), { status: "failed", error: { code: 131026, message: "to 919000000001 undeliverable" } }, "N")
    expect(p?.delivery_status).toBe("failed")
    expect(p?.failed_at).toBe("N")
    expect(String(p?.error)).toContain("delivery_failed")
    expect(String(p?.error)).not.toContain("919000000001")
    expect(applyStatusEvent(cur({ delivery_status: "delivered", delivered_at: "D" }), { status: "failed" }, "N")).toBeNull()
  })
  it("never writes `status` (that column is the send confirmation)", () => {
    for (const s of ["sent", "delivered", "read", "failed"]) {
      const p = applyStatusEvent(cur({ delivery_status: null }), { status: s }, "N")
      expect(p).not.toHaveProperty("status")
    }
  })
  it("ignores unknown statuses", () => {
    expect(applyStatusEvent(cur(), { status: "teleported" }, "N")).toBeNull()
  })
  it("uses the event's own timestamp when it has a valid one", () => {
    const p = applyStatusEvent(cur(), { status: "delivered", at: "2026-10-12T11:46:15.000Z" }, "N")
    expect(p?.delivered_at).toBe("2026-10-12T11:46:15.000Z")
  })
})

describe("handleWasiWebhook: message.status", () => {
  it("verified: acknowledges 200 immediately and applies the update through defer", async () => {
    const { store, applied } = makeStore({}, row0)
    const d = deferCollector()
    const raw = statusBody("delivered")
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer, () => "NOW")
    expect(res.status).toBe(200)
    // processing happens after the response is decided: nothing has been written yet, it is queued
    expect(d.count()).toBe(1)
    await d.settle()
    expect(applied).toEqual([{ id: "out-1", patch: { delivery_status: "delivered", delivered_at: "NOW" } }])
  })

  it("bad signature: 401 and NO write", async () => {
    const { store, applied } = makeStore({}, row0)
    const d = deferCollector()
    const raw = statusBody("delivered")
    const res = await handleWasiWebhook(raw, await sign(raw, "wrong-secret"), store, d.defer)
    expect(res.status).toBe(401)
    await d.settle()
    expect(applied).toEqual([])
    expect(d.count()).toBe(0)
  })

  it("missing signature header: 401, no write", async () => {
    const { store, applied } = makeStore({}, row0)
    const d = deferCollector()
    const res = await handleWasiWebhook(statusBody("read"), null, store, d.defer)
    expect(res.status).toBe(401)
    expect(applied).toEqual([])
  })

  it("unknown message id: 200, no write (no org means no secret to verify against)", async () => {
    const { store, applied } = makeStore({}, undefined)
    const d = deferCollector()
    const raw = statusBody("delivered")
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    expect(res.status).toBe(200)
    expect(res.body.matched).toBe(false)
    await d.settle()
    expect(applied).toEqual([])
  })

  it("duplicate / regressing event: 200 and no write", async () => {
    const { store, applied } = makeStore({}, { id: "out-1", delivery_status: "read", delivered_at: "D", read_at: "R" })
    const d = deferCollector()
    const raw = statusBody("delivered")
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    expect(res.status).toBe(200)
    await d.settle()
    expect(applied).toEqual([])
  })

  it("failed event is stored with Wasi's error", async () => {
    const { store, applied } = makeStore({}, row0)
    const d = deferCollector()
    const raw = statusBody("failed", { error: { code: 131047, message: "re-engagement" } })
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer, () => "NOW")
    expect(res.status).toBe(200)
    await d.settle()
    expect(applied[0].patch.delivery_status).toBe("failed")
    expect(String(applied[0].patch.error)).toContain("131047")
  })

  it("a store failure during processing is swallowed (already acknowledged) and not logged with identifiers", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { store } = makeStore({ applyDeliveryUpdate: async () => { throw new Error("db down") } }, row0)
    const d = deferCollector()
    const raw = statusBody("delivered")
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    expect(res.status).toBe(200)
    await d.settle()
    const logged = JSON.stringify(spy.mock.calls)
    expect(logged).toContain("db down")
    expect(logged).not.toContain("SYNTHETIC")
    spy.mockRestore()
  })
})

describe("handleWasiWebhook: message.received", () => {
  const received = (over: Record<string, unknown> = {}) =>
    JSON.stringify({
      event: "message.received",
      data: { message_id: "m-1", message_type: "text", contact: { wa_id: "919000000001" }, message: { body: "hi", sent_at: "2026-10-12T11:50:00Z" }, waba_id: "waba-1", ...over },
    })

  it("verified: 200 is returned without waiting for the bot, which runs through defer", async () => {
    let release!: () => void
    const gate = new Promise<void>((r) => (release = r))
    let finished = false
    const { store } = makeStore({
      processInbound: async () => {
        await gate
        finished = true
      },
    })
    const d = deferCollector()
    const raw = received()
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    // the handler already answered while the bot is still blocked
    expect(res.status).toBe(200)
    expect(finished).toBe(false)
    expect(d.count()).toBe(1)
    release()
    await d.settle()
    expect(finished).toBe(true)
  })

  it("bad signature: 401 and the bot never runs", async () => {
    const { store, inbound } = makeStore()
    const d = deferCollector()
    const raw = received()
    const res = await handleWasiWebhook(raw, await sign(raw, "nope"), store, d.defer)
    expect(res.status).toBe(401)
    await d.settle()
    expect(inbound).toEqual([])
  })

  it("unknown waba_id and missing waba_id are 401", async () => {
    const { store } = makeStore()
    const d = deferCollector()
    expect((await handleWasiWebhook(received({ waba_id: "other" }), "sha256=00", store, d.defer)).status).toBe(401)
    expect((await handleWasiWebhook(received({ waba_id: undefined }), "sha256=00", store, d.defer)).status).toBe(401)
  })

  it("bot errors are caught: Wasi still gets its 200", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { store } = makeStore({ processInbound: async () => { throw new Error("boom") } })
    const d = deferCollector()
    const raw = received()
    const res = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    expect(res.status).toBe(200)
    await d.settle()
    spy.mockRestore()
  })

  it("normalises text, interactive and body-bearing other types", () => {
    const base = { message_id: "m", contact: { wa_id: "919000000001" }, waba_id: "w" }
    expect(toNormalized({ ...base, message_type: "text", message: { body: "hi" } })?.intent).toEqual({ kind: "text", text: "hi" })
    expect(toNormalized({ ...base, message_type: "interactive", message: { interactive: { type: "button_reply", id: "buy", title: "Buy" } } })?.intent).toEqual({ kind: "list_reply", id: "buy" })
    expect(toNormalized({ ...base, message_type: "image", message: { body: "caption" } })?.intent).toEqual({ kind: "text", text: "caption" })
    expect(toNormalized({ ...base, message_type: "image" })).toBeNull()
  })
})

describe("handleWasiWebhook: other events", () => {
  it("template status update is verified before it is applied", async () => {
    const { store, templates } = makeStore()
    const d = deferCollector()
    const raw = JSON.stringify({ event: "message_template_status_update", data: { waba_id: "waba-1", name: "gvm_x_en", status: "APPROVED" } })
    expect((await handleWasiWebhook(raw, await sign(raw, "bad"), store, d.defer)).status).toBe(401)
    expect(templates).toEqual([])
    const ok = await handleWasiWebhook(raw, await sign(raw), store, d.defer)
    expect(ok.status).toBe(200)
    await d.settle()
    expect(templates).toEqual([{ org: "org-1", name: "gvm_x_en", status: "approved" }])
  })

  it("account_update and unknown events are acknowledged without action", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { store, applied } = makeStore()
    const d = deferCollector()
    const res = await handleWasiWebhook(JSON.stringify({ event: "account_update", data: {} }), null, store, d.defer)
    expect(res.status).toBe(200)
    expect(applied).toEqual([])
    spy.mockRestore()
  })

  it("invalid JSON is a 400", async () => {
    const { store } = makeStore()
    expect((await handleWasiWebhook("{nope", null, store, () => {})).status).toBe(400)
  })
})
