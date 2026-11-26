import { describe, expect, it } from "vitest"
import { complaintDetailsStepSchema, EMPTY_COMPLAINT_DETAILS } from "./service"
import { ENQUIRY_TYPE_REQUIRED, enquiryLeadSchema, fromYesNo, roChecklistSchema, servicePaymentSchema, toYesNo } from "./technician"
import { PAYMENT_METHOD_REQUIRED } from "./sale"

/** choice-dropdowns-not-set (build-docs/features/choice-dropdowns-not-set.md): service, on-site visit and task choices. */

const firstIssue = (r: { error?: { issues: { path: PropertyKey[]; message: string }[] } }) => {
  const i = r.error?.issues[0]
  return i ? `${i.path.join(".")}:${i.message}` : undefined
}

describe("New complaint priority (class C)", () => {
  const filled = { nameOfComplaint: "Not cooling", natureOfComplaint: "" }

  it("AC1: new complaint has no priority pre-selected", () => {
    expect(EMPTY_COMPLAINT_DETAILS.priority).toBe("")
  })

  it("AC2: Not set priority blocks save with Choose an option", () => {
    expect(firstIssue(complaintDetailsStepSchema.safeParse({ ...filled, priority: "" }))).toBe("priority:service.errors.priorityRequired")
  })

  it("AC2: a draft that lost the priority key is still blocked", () => {
    expect(firstIssue(complaintDetailsStepSchema.safeParse(filled))).toBe("priority:service.errors.priorityRequired")
  })

  it("AC2: each chosen priority passes", () => {
    for (const priority of ["very_urgent", "urgent", "normal"] as const) {
      expect(complaintDetailsStepSchema.safeParse({ ...filled, priority }).success).toBe(true)
    }
  })

  it("draft save/restore keeps an unset priority unset", () => {
    expect(JSON.parse(JSON.stringify(EMPTY_COMPLAINT_DETAILS))).toEqual(EMPTY_COMPLAINT_DETAILS)
  })

  it("edit keeps saved value: a restored draft with a chosen priority passes unchanged", () => {
    const r = complaintDetailsStepSchema.safeParse(JSON.parse(JSON.stringify({ ...filled, priority: "urgent" })))
    expect(r.data?.priority).toBe("urgent")
  })
})

describe("On-site RO checklist Yes/No + water source (class A)", () => {
  const base = { clientName: "Ravi", tankCleaned: null, productExplained: null }

  it("AC1: unanswered shows Not set", () => {
    expect(toYesNo(null)).toBe("")
  })

  it("A: tank cleaned / product explained Not set saves null", () => {
    expect(fromYesNo("")).toBeNull()
    const r = roChecklistSchema.safeParse(base)
    expect(r.success).toBe(true)
    expect(r.data).toMatchObject({ tankCleaned: null, productExplained: null })
  })

  it("Yes/No map to true/false and back", () => {
    expect(fromYesNo("yes")).toBe(true)
    expect(fromYesNo("no")).toBe(false)
    expect(toYesNo(true)).toBe("yes")
    expect(toYesNo(false)).toBe("no")
  })

  it("A: water source Not set saves null", () => {
    const r = roChecklistSchema.safeParse({ ...base, waterSource: null })
    expect(r.success).toBe(true)
    expect(r.data?.waterSource).toBeNull()
  })

  it("edit keeps saved value: a chosen water source passes", () => {
    expect(roChecklistSchema.safeParse({ ...base, tankCleaned: true, waterSource: "borewater" }).data).toMatchObject({
      tankCleaned: true,
      waterSource: "borewater",
    })
  })
})

describe("On-site payment method (class C)", () => {
  it("AC2: Not set payment method blocks completing with Choose a payment method", () => {
    expect(firstIssue(servicePaymentSchema.safeParse({ method: "" }))).toBe(`method:${PAYMENT_METHOD_REQUIRED}`)
    expect(firstIssue(servicePaymentSchema.safeParse({}))).toBe(`method:${PAYMENT_METHOD_REQUIRED}`)
  })

  it("AC2: a chosen method passes", () => {
    expect(servicePaymentSchema.safeParse({ method: "cash" }).success).toBe(true)
  })

  it("known open bug unchanged: UPI is still rejected, but not with the Not-set message", () => {
    const r = servicePaymentSchema.safeParse({ method: "upi" })
    expect(r.success).toBe(false)
    expect(r.error?.issues[0]?.message).not.toBe(PAYMENT_METHOD_REQUIRED)
  })
})

describe("On-site generate enquiry type (class C)", () => {
  it("AC2: Not set enquiry type blocks Send with Choose an option", () => {
    expect(firstIssue(enquiryLeadSchema.safeParse({ name: "Ravi", enquiryType: "" }))).toBe(`enquiryType:${ENQUIRY_TYPE_REQUIRED}`)
  })

  it("AC2: a chosen type passes", () => {
    expect(enquiryLeadSchema.safeParse({ name: "Ravi", enquiryType: "online" }).success).toBe(true)
  })
})
