import { describe, expect, it } from "vitest"
import en from "./en.json"
import ta from "./ta.json"

/** choice-dropdowns-not-set: every literal message/label key the change uses must exist as text in both languages
 * (service.errors.* was missing entirely before this change, so the complaint form showed raw keys). */
const KEYS = [
  "automation.segments.matchAll",
  "automation.segments.no",
  "automation.segments.ofTheseConditions",
  "automation.segments.opAnd",
  "automation.segments.opOr",
  "automation.segments.operator.contains",
  "automation.segments.operator.equals",
  "automation.segments.valuePlaceholder",
  "automation.segments.yes",
  "automation.templates.category",
  "customers.form.memberRelation",
  "expenses.adjustments.exclude",
  "expenses.adjustments.target",
  "expenses.adjustments.topUp",
  "expenses.adjustments.type",
  "expenses.bikeAssignment.ownership",
  "hr.staffSalary.role",
  "leads.detail.lostReasonLabel",
  "leads.edit.referralLockedHint",
  "leads.errors.sourceRequired",
  "leads.followup.setType",
  "leads.followup.typeRequired",
  "leads.new.enquiryType",
  "leads.new.kind",
  "leads.new.productCategory",
  "leads.new.source",
  "leads.outcomeSheet.channelRequired",
  "leads.outcomeSheet.followupNeeded",
  "leads.outcomeSheet.how",
  "leads.outcomeSheet.nextType",
  "leads.outcomeSheet.nextTypeRequired",
  "leads.outcomeSheet.no",
  "leads.outcomeSheet.noFollowupHint",
  "leads.outcomeSheet.step1",
  "leads.outcomeSheet.step2",
  "leads.outcomeSheet.step3",
  "leads.outcomeSheet.yes",
  "leads.postService.whatHappened",
  "masters.productEnquiryConfig.dataType",
  "masters.productEnquiryConfig.field",
  "masters.productFeatures.relationTypeLabel",
  "masters.productMedia.docTypeLabel",
  "masters.tabs.products",
  "masters.tabs.spares",
  "productLifecycle.lifetime.errors.unitRequired",
  "productLifecycle.lifetime.unitLabel",
  "reports.errors.expenseCategoryRequired",
  "reports.pnl.category",
  "sales.payment.method",
  "service.detail.confirmedAvailability.reasonLabel",
  "service.detail.confirmedAvailability.reasonRequired",
  "service.newComplaint.priority",
  "tasks.assignDialog.priority",
  "technician.onsite.enquiryConfirm.title",
  "technician.onsite.payment.method",
  "technician.onsite.ro.productExplained",
  "technician.onsite.ro.tankCleaned",
  "technician.onsite.ro.waterSource"
]

const get = (o: unknown, k: string) => k.split(".").reduce<unknown>((x, p) => (x && typeof x === "object" ? (x as Record<string, unknown>)[p] : undefined), o)

describe("choice-dropdowns-not-set i18n keys", () => {
  it.each(KEYS)("%s exists in en and ta", (k) => {
    expect(typeof get(en, k)).toBe("string")
    expect(typeof get(ta, k)).toBe("string")
  })
})
