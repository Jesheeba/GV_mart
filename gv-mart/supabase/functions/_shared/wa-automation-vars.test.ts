import { describe, expect, it } from "vitest"
import { amcContractVars, automationPayloadLanguage, automationPayloadVars, formatIstCalendarDate, isAutomationRow } from "./wa-automation-vars"

describe("wa-automation-vars", () => {
  it("formats a date-only value as an IST calendar date (no day shift)", () => {
    expect(formatIstCalendarDate("2026-10-12")).toBe("12 Oct 2026")
    expect(formatIstCalendarDate("2027-01-01")).toBe("1 Jan 2027")
    expect(formatIstCalendarDate("2026-10-12T20:00:00Z")).toBe("12 Oct 2026")
    expect(formatIstCalendarDate("bad")).toBeNull()
    expect(formatIstCalendarDate(null)).toBeNull()
  })

  it("reads the language the engine resolved, only en or ta", () => {
    expect(automationPayloadLanguage({ language: "ta" })).toBe("ta")
    expect(automationPayloadLanguage({ language: "en" })).toBe("en")
    expect(automationPayloadLanguage({ language: "fr" })).toBeNull()
    expect(automationPayloadLanguage(null)).toBeNull()
  })

  it("recognises hand-off rows by the queue id", () => {
    expect(isAutomationRow({ automation_queue_id: "q1" })).toBe(true)
    expect(isAutomationRow({ ticket_id: "t" })).toBe(false)
    expect(isAutomationRow(undefined)).toBe(false)
  })

  it("eta, days and dates become template variables", () => {
    expect(automationPayloadVars({ eta_minutes: 45 })).toEqual({ eta: "45 minutes" })
    expect(automationPayloadVars({ eta_minutes: 1 })).toEqual({ eta: "1 minute" })
    expect(automationPayloadVars({ days_left: 7, expiry_date: "2026-11-01", visit_date: "2026-10-20" })).toEqual({
      days_left: "7",
      days: "7",
      expiry_date: "1 Nov 2026",
      visit_date: "20 Oct 2026",
    })
    expect(automationPayloadVars({ eta_minutes: 0, days_left: -1 })).toEqual({})
    expect(automationPayloadVars({ eta_minutes: "abc" })).toEqual({})
    expect(automationPayloadVars(null)).toEqual({})
  })

  it("never turns a number or a name from the payload into a variable", () => {
    const v = automationPayloadVars({ mobile: "9400000081", name: "Priya", technician_id: "x", eta_minutes: 30 })
    expect(Object.keys(v)).toEqual(["eta"])
  })

  it("AMC variables: contract record first, hand-off context wins for this message", () => {
    const v = amcContractVars({ expiry_date: "2027-03-31", next_service_date: "2026-12-01" }, "Aquaguard RO", "Gold", {
      days_left: 15,
      visit_date: "2026-11-02",
    })
    expect(v).toEqual({
      product: "Aquaguard RO",
      product_name: "Aquaguard RO",
      plan: "Gold",
      plan_name: "Gold",
      expiry_date: "31 Mar 2027",
      visit_date: "2 Nov 2026",
      days_left: "15",
      days: "15",
    })
    expect(amcContractVars(null, null, null, null)).toEqual({})
  })
})
