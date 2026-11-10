import { describe, expect, it } from "vitest"
import { resolveGreetingName } from "./dashboardGreeting"

describe("dashboard greeting name per role", () => {
  it("master shows the org name, not the shared account's own name", () => {
    expect(resolveGreetingName({ role: "master", full_name: "Ramesh Kumar" }, "GV Mart")).toBe("GV Mart")
  })

  it("operation_admin keeps their own first name", () => {
    expect(resolveGreetingName({ role: "operation_admin", full_name: "Suresh Babu" }, undefined)).toBe("Suresh")
  })

  it("sales_admin keeps their own first name", () => {
    expect(resolveGreetingName({ role: "sales_admin", full_name: "Priya Dharshini" }, undefined)).toBe("Priya")
  })

  it("master falls back to first name while the org is still loading", () => {
    expect(resolveGreetingName({ role: "master", full_name: "Ramesh Kumar" }, undefined)).toBe("Ramesh")
  })
})
