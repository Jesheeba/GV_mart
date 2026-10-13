import { describe, expect, it, vi } from "vitest"
import { detectOptOutKeyword, foldKeyword, handleOptOutKeyword, optOutLanguage, optOutReply } from "./wa-opt-out"

type Row = { opt_out_non_job: boolean; opt_out_all: boolean } | null

function fakeAdmin(prefs: Row, rpcError: { code?: string; message?: string } | null = null) {
  const rpc = vi.fn(async () => ({ data: null, error: rpcError }))
  const maybeSingle = vi.fn(async () => ({ data: prefs, error: null }))
  const chain: Record<string, unknown> = {}
  chain.select = () => chain
  chain.eq = () => chain
  chain.maybeSingle = maybeSingle
  const from = vi.fn(() => chain)
  return { admin: { rpc, from } as never, rpc, from }
}

describe("detectOptOutKeyword", () => {
  it("recognises STOP, STOP ALL and START in any case, with punctuation and emoji", () => {
    expect(detectOptOutKeyword("STOP")).toBe("stop")
    expect(detectOptOutKeyword("  stop. ")).toBe("stop")
    expect(detectOptOutKeyword("Unsubscribe!")).toBe("stop")
    expect(detectOptOutKeyword("STOP ALL")).toBe("stop_all")
    expect(detectOptOutKeyword("stop   all")).toBe("stop_all")
    expect(detectOptOutKeyword("StopAll")).toBe("stop_all")
    expect(detectOptOutKeyword("Stop all messages 🙏")).toBe("stop_all")
    expect(detectOptOutKeyword("START")).toBe("start")
    expect(detectOptOutKeyword("subscribe")).toBe("start")
  })

  it("recognises the Tamil forms", () => {
    expect(detectOptOutKeyword("நிறுத்து")).toBe("stop")
    expect(detectOptOutKeyword("நிறுத்துங்கள்")).toBe("stop")
    expect(detectOptOutKeyword("அனைத்தையும் நிறுத்து")).toBe("stop_all")
    expect(detectOptOutKeyword("தொடங்கு")).toBe("start")
  })

  it("only matches the whole message, never a word inside a sentence", () => {
    expect(detectOptOutKeyword("please stop the leak")).toBeNull()
    expect(detectOptOutKeyword("my RO will not stop")).toBeNull()
    expect(detectOptOutKeyword("stop sending reminders please")).toBeNull()
    expect(detectOptOutKeyword("start the service")).toBeNull()
    expect(detectOptOutKeyword("1")).toBeNull()
    expect(detectOptOutKeyword("")).toBeNull()
    expect(detectOptOutKeyword(null)).toBeNull()
    expect(detectOptOutKeyword(undefined)).toBeNull()
    expect(detectOptOutKeyword("stop ".repeat(30))).toBeNull()
  })

  it("foldKeyword keeps Tamil letters and drops punctuation", () => {
    expect(foldKeyword("  Stop!!  ALL ")).toBe("stop all")
    expect(foldKeyword("நிறுத்து.")).toBe("நிறுத்து")
  })

  it("language: Tamil script gives ta, everything else en", () => {
    expect(optOutLanguage("நிறுத்து")).toBe("ta")
    expect(optOutLanguage("STOP")).toBe("en")
    expect(optOutReply("stop", "en")).toContain("invoices")
    expect(optOutReply("stop", "ta")).toContain("இன்வாய்ஸ்")
    expect(optOutReply("stop_all", "en")).toContain("START")
  })
})

describe("handleOptOutKeyword", () => {
  it("STOP: records the opt-out and sends exactly one confirmation to the same number", async () => {
    const { admin, rpc } = fakeAdmin(null)
    const send = vi.fn(async () => undefined)
    const handled = await handleOptOutKeyword(admin, "org1", "919400000061", "STOP", send)
    expect(handled).toBe(true)
    expect(rpc).toHaveBeenCalledWith("wa_record_opt_out", { p_org: "org1", p_mobile: "9400000061", p_action: "stop", p_source: "whatsapp" })
    expect(send).toHaveBeenCalledTimes(1)
    const sent = (send.mock.calls[0] as unknown[])[0] as { to: string; template: string; body: string }
    expect(sent.to).toBe("9400000061")
    expect(sent.template).toBe("wa.opt_out.stop")
    expect(sent.body).toMatch(/invoices/i)
  })

  it("STOP ALL is recorded as stop_all", async () => {
    const { admin, rpc } = fakeAdmin(null)
    const send = vi.fn(async () => undefined)
    expect(await handleOptOutKeyword(admin, "org1", "9400000061", "stop all", send)).toBe(true)
    expect(rpc).toHaveBeenCalledWith("wa_record_opt_out", expect.objectContaining({ p_action: "stop_all" }))
  })

  it("Tamil STOP gets a Tamil confirmation", async () => {
    const { admin } = fakeAdmin(null)
    const send = vi.fn(async () => undefined)
    await handleOptOutKeyword(admin, "org1", "9400000061", "நிறுத்து", send)
    const sent = (send.mock.calls[0] as unknown[])[0] as { body: string }
    expect(/[஀-௿]/.test(sent.body)).toBe(true)
  })

  it("START resubscribes only when an opt-out is on record", async () => {
    const opted = fakeAdmin({ opt_out_non_job: true, opt_out_all: false })
    const send = vi.fn(async () => undefined)
    expect(await handleOptOutKeyword(opted.admin, "org1", "9400000061", "START", send)).toBe(true)
    expect(opted.rpc).toHaveBeenCalledWith("wa_record_opt_out", expect.objectContaining({ p_action: "start" }))
    expect(send).toHaveBeenCalledTimes(1)

    const clean = fakeAdmin({ opt_out_non_job: false, opt_out_all: false })
    const send2 = vi.fn(async () => undefined)
    expect(await handleOptOutKeyword(clean.admin, "org1", "9400000061", "start", send2)).toBe(false)
    expect(clean.rpc).not.toHaveBeenCalled()
    expect(send2).not.toHaveBeenCalled()

    const none = fakeAdmin(null)
    expect(await handleOptOutKeyword(none.admin, "org1", "9400000061", "start", send2)).toBe(false)
    expect(none.rpc).not.toHaveBeenCalled()
  })

  it("an ordinary message is not handled and nothing is written or sent", async () => {
    const { admin, rpc } = fakeAdmin(null)
    const send = vi.fn(async () => undefined)
    expect(await handleOptOutKeyword(admin, "org1", "9400000061", "my RO is leaking, please stop by today", send)).toBe(false)
    expect(rpc).not.toHaveBeenCalled()
    expect(send).not.toHaveBeenCalled()
  })

  it("if the record cannot be written, the message falls through to the bot (not swallowed) and nothing is sent", async () => {
    const { admin } = fakeAdmin(null, { code: "XX000", message: "boom" })
    const send = vi.fn(async () => undefined)
    const spy = vi.spyOn(console, "error").mockImplementation(() => undefined)
    expect(await handleOptOutKeyword(admin, "org1", "9400000061", "STOP", send)).toBe(false)
    expect(send).not.toHaveBeenCalled()
    spy.mockRestore()
  })

  it("a malformed phone is not handled", async () => {
    const { admin, rpc } = fakeAdmin(null)
    const send = vi.fn(async () => undefined)
    expect(await handleOptOutKeyword(admin, "org1", "12345", "STOP", send)).toBe(false)
    expect(rpc).not.toHaveBeenCalled()
  })
})
