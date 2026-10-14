import { describe, expect, it } from "vitest"
import { isHttpsUrl } from "./httpsUrl"

describe("isHttpsUrl", () => {
  it("accepts https links", () => {
    expect(isHttpsUrl("https://youtu.be/AbCdEfGhIjK")).toBe(true)
    expect(isHttpsUrl("HTTPS://example.com/v")).toBe(true)
  })
  it("rejects http, other schemes, spaces and an empty host", () => {
    expect(isHttpsUrl("http://youtu.be/x")).toBe(false)
    expect(isHttpsUrl("javascript:alert(1)")).toBe(false)
    expect(isHttpsUrl("https://youtu.be/a b")).toBe(false)
    expect(isHttpsUrl("https://")).toBe(false)
    expect(isHttpsUrl("youtu.be/x")).toBe(false)
  })
})
