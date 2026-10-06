import { describe, expect, it } from "vitest"
import { buildWasiErrorDetail, redactWasiText, WASI_ERROR_BODY_MAX_CHARS } from "./wasi-error-detail"

const headers = (h: Record<string, string>) => ({ get: (n: string) => h[n.toLowerCase()] ?? null })

describe("buildWasiErrorDetail", () => {
  const FAKE_TOKEN = "FAKEWASIKEY9f8e7d6c5b4a39281706f5e4d3c2b1a0"
  const FAKE_JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV"
  const body = JSON.stringify({
    code: 409,
    message: "Recipient 919876543210 is outside the 24h window",
    debug: { api_key: FAKE_TOKEN, authorization: `Bearer ${FAKE_JWT}`, to: "+919876543210" },
  })

  it("keeps the original summary first and stores the cleaned body", () => {
    const out = buildWasiErrorDetail("409: unknown_error", body)
    expect(out.startsWith("409: unknown_error | body: ")).toBe(true)
    expect(out).toContain("outside the 24h window")
  })

  it("strips tokens and masks phone numbers from what is stored", () => {
    const out = buildWasiErrorDetail("409: unknown_error", body, headers({ "content-type": "application/json" }))
    expect(out).not.toContain(FAKE_TOKEN)
    expect(out).not.toContain(FAKE_JWT)
    expect(out).not.toContain("9876543210")
    expect(out).not.toMatch(/Bearer\s+eyJ/)
    expect(out).toContain("[redacted]")
    expect(out).toContain("91********10") // 12-digit run: first 2 + last 2 kept
  })

  it("redacts bare Bearer headers, key=value secrets and JWT-shaped strings", () => {
    expect(redactWasiText("Authorization: Bearer abcDEF123456789xyz")).not.toContain("abcDEF123456789xyz")
    expect(redactWasiText("token=supersecretvalue&x=1")).not.toContain("supersecretvalue")
    expect(redactWasiText(`oops ${FAKE_JWT} oops`)).not.toContain(FAKE_JWT)
  })

  it("does not mangle ordinary short numbers and ids", () => {
    const out = redactWasiText('{"code":409,"retry_after":30,"ticket":"1234567"}')
    expect(out).toContain('"code":409')
    expect(out).toContain('"retry_after":30')
    expect(out).toContain("1234567")
  })

  it("keeps UUIDs and wamid message ids, which support needs", () => {
    const out = redactWasiText('{"ref":"c26def1e-a050-49ee-a876-d73033a2a287","id":"wamid.HBgMOTE5MDkyNzY2NzQwFQIAEhggQUNDNzVCNkEwQTQ2N0ZFRUYzRDc3QzNGN0Y4RjFBOTUA"}')
    expect(out).toContain("c26def1e-a050-49ee-a876-d73033a2a287")
    expect(out).toContain("wamid.HBgMOTE5MDkyNzY2NzQwFQIAEhggQUNDNzVCNkEwQTQ2N0ZFRUYzRDc3QzNGN0Y4RjFBOTUA")
  })

  it("truncates the body to the cap with an ellipsis", () => {
    const out = buildWasiErrorDetail("500: boom", "x ".repeat(2000))
    const stored = out.slice(out.indexOf("body: ") + "body: ".length)
    expect(stored.length).toBeLessThanOrEqual(WASI_ERROR_BODY_MAX_CHARS)
    expect(stored.endsWith("…")).toBe(true)
  })

  it("keeps only allowlisted headers, never auth or cookies", () => {
    const out = buildWasiErrorDetail(
      "429: slow_down",
      "",
      headers({
        "content-type": "application/json",
        "x-request-id": "req-123",
        "retry-after": "30",
        authorization: "Bearer topsecrettoken123",
        "set-cookie": "session=abc123def456",
      })
    )
    expect(out).toContain("content-type=application/json")
    expect(out).toContain("x-request-id=req-123")
    expect(out).toContain("retry-after=30")
    expect(out).not.toContain("topsecrettoken123")
    expect(out).not.toContain("abc123def456")
    expect(out).not.toContain("body:") // empty body segment omitted
  })

  it("returns just the summary when there is nothing else to add", () => {
    expect(buildWasiErrorDetail("409: unknown_error", "")).toBe("409: unknown_error")
  })
})
