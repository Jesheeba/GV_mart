import { describe, expect, it } from "vitest"
import type { CrudFieldDef } from "@/components/shared/EntityCrudTable"
import { initialFormValues, selectNeedsChoice, validateFields } from "./crudForm"

/** choice-no-preselect: EntityCrudTable master add-forms start selects at "Select…" (AC5); status fields keep their DB default (AC6). */

const t = (key: string, opts?: Record<string, unknown>) => `${key}|${String(opts?.field ?? "")}`

const category: CrudFieldDef = {
  key: "category",
  label: "Category",
  type: "select",
  options: [
    { value: "ro", label: "RO" },
    { value: "softener", label: "Softener" },
  ],
}
const isActive: CrudFieldDef = {
  key: "is_active",
  label: "Status",
  type: "select",
  defaultValue: "true",
  options: [
    { value: "true", label: "Active" },
    { value: "false", label: "Inactive" },
  ],
}
const anyProduct: CrudFieldDef = {
  key: "product_id",
  label: "Product",
  type: "select",
  options: [
    { value: "", label: "Any product" },
    { value: "p1", label: "Aqua" },
  ],
}
const name: CrudFieldDef = { key: "name", label: "Name", type: "text", required: true }
const fields = [name, category, isActive, anyProduct]

describe("initialFormValues", () => {
  it("AC1/AC5: a select starts empty (the Select… placeholder), never at its first option", () => {
    expect(initialFormValues(fields).category).toBe("")
  })

  it("AC6: a status field with defaultValue keeps it (is_active → Active)", () => {
    expect(initialFormValues(fields).is_active).toBe("true")
  })

  it("a select with its own empty option starts on that option, and text fields start empty", () => {
    expect(initialFormValues(fields)).toEqual({ name: "", category: "", is_active: "true", product_id: "" })
  })

  it("AC5: a late-loading option list doesn't change the starting value", () => {
    const brand: CrudFieldDef = { key: "brand_id", label: "Brand", type: "select", options: [] }
    expect(initialFormValues([brand]).brand_id).toBe("")
  })
})

describe("selectNeedsChoice", () => {
  it("is true for a select without an empty option, false when empty is itself a choice or for non-selects", () => {
    expect(selectNeedsChoice(category, {})).toBe(true)
    expect(selectNeedsChoice(anyProduct, {})).toBe(false)
    expect(selectNeedsChoice(name, {})).toBe(false)
  })

  it("follows options derived from the in-progress values", () => {
    const target: CrudFieldDef = {
      key: "target",
      label: "Field",
      type: "select",
      options: (v) => (v.source === "none" ? [{ value: "", label: "—" }] : [{ value: "price", label: "Price" }]),
    }
    expect(selectNeedsChoice(target, { source: "product_field" })).toBe(true)
    expect(selectNeedsChoice(target, { source: "none" })).toBe(false)
  })
})

describe("validateFields", () => {
  const valid = { name: "Aqua", category: "ro", is_active: "true", product_id: "" }

  it("AC2/AC5: an untouched select blocks save with an error keyed to that field", () => {
    expect(validateFields(fields, { ...valid, category: "" }, t)).toEqual({ key: "category", message: "common.errors.fieldRequired|Category" })
  })

  it("AC5: choosing an option clears the block", () => {
    expect(validateFields(fields, valid, t)).toBeNull()
  })

  it("an empty value that is itself an option (Any product) is accepted", () => {
    expect(validateFields(fields, { ...valid, product_id: "" }, t)).toBeNull()
  })

  it("AC3: an edit payload with the row's saved values passes", () => {
    expect(validateFields(fields, { name: "Old", category: "softener", is_active: "false", product_id: "p1" }, t)).toBeNull()
  })

  it("keeps reporting the first failing field in field order (existing text rules unchanged)", () => {
    expect(validateFields(fields, { ...valid, name: "", category: "" }, t)?.key).toBe("name")
  })
})
