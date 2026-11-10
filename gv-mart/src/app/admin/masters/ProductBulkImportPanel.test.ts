import { describe, expect, it } from "vitest"
import { TEMPLATE_HEADER, parseRows, type BrandRow, type ExistingProduct, type ModelRow } from "./ProductBulkImportPanel"

const brands: BrandRow[] = [
  { id: "b1", name: "Aquafresh" },
  { id: "b2", name: "Kent" },
]
const models: ModelRow[] = [
  { id: "m1", name: "AF-700", brand_id: "b1" },
  { id: "m2", name: "K-100", brand_id: "b2" },
]
const existingProducts: ExistingProduct[] = [
  { id: "p1", name: "Existing RO", brand_id: "b1", model_id: "m1", item_code: "EXIST-01" },
]

function csvRows(...dataRows: string[][]) {
  return [TEMPLATE_HEADER, ...dataRows]
}

describe("parseRows", () => {
  it("resolves a fully valid row with brand/model matched by name, case-insensitively", () => {
    const { rows, headerError } = parseRows(
      csvRows(["Aquafresh RO 7L", "aquafresh", "af-700", "ro", "12000", "84212100", "AF700-01", "5", "10"]),
      brands,
      models,
      existingProducts
    )
    expect(headerError).toBeNull()
    expect(rows).toHaveLength(1)
    expect(rows[0].errors).toEqual([])
    expect(rows[0].isDuplicate).toBe(false)
    expect(rows[0].resolved).toMatchObject({
      name: "Aquafresh RO 7L",
      brandId: "b1",
      modelId: "m1",
      category: "ro",
      price: 12000,
      hsnCode: "84212100",
      itemCode: "AF700-01",
      openingStock: 5,
      minStock: 10,
    })
  })

  it("leaves opening_stock/reorder_level null when blank, never defaulting them client-side", () => {
    const { rows } = parseRows(csvRows(["X", "Aquafresh", "AF-700", "ro", "100", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors).toEqual([])
    expect(rows[0].resolved?.openingStock).toBeNull()
    expect(rows[0].resolved?.minStock).toBeNull()
  })

  it("flags an unmatched brand as a row error and does NOT resolve the row", () => {
    const { rows } = parseRows(csvRows(["X", "NoSuchBrand", "AF-700", "ro", "100", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors.some((e) => e.includes('brand not found: "NoSuchBrand"'))).toBe(true)
    expect(rows[0].resolved).toBeNull()
  })

  it("flags a model that doesn't belong to the matched brand", () => {
    const { rows } = parseRows(csvRows(["X", "Aquafresh", "K-100", "ro", "100", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors.some((e) => e.includes("model not found for brand"))).toBe(true)
    expect(rows[0].resolved).toBeNull()
  })

  it("flags an invalid category", () => {
    const { rows } = parseRows(csvRows(["X", "Aquafresh", "AF-700", "fridge", "100", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors.some((e) => e.includes("category must be one of"))).toBe(true)
  })

  it("flags a negative or non-numeric price", () => {
    const { rows } = parseRows(csvRows(["X", "Aquafresh", "AF-700", "ro", "-5", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors.some((e) => e.includes("price must be a number"))).toBe(true)
  })

  it("flags an item_code already used by an existing product", () => {
    const { rows } = parseRows(csvRows(["X", "Aquafresh", "AF-700", "ro", "100", "", "EXIST-01", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors.some((e) => e.includes("already used by an existing product"))).toBe(true)
  })

  it("flags an item_code duplicated within the same file, on the second occurrence", () => {
    const { rows } = parseRows(
      csvRows(
        ["X", "Aquafresh", "AF-700", "ro", "100", "", "DUP-01", "", ""],
        ["Y", "Aquafresh", "AF-700", "ro", "100", "", "DUP-01", "", ""]
      ),
      brands,
      models,
      existingProducts
    )
    expect(rows[0].errors).toEqual([])
    expect(rows[1].errors.some((e) => e.includes("duplicated elsewhere in this file"))).toBe(true)
  })

  it("warns (does not block) on a same name+brand+model match against an existing product", () => {
    const { rows } = parseRows(csvRows(["Existing RO", "Aquafresh", "AF-700", "ro", "100", "", "", "", ""]), brands, models, existingProducts)
    expect(rows[0].errors).toEqual([])
    expect(rows[0].isDuplicate).toBe(true)
    expect(rows[0].resolved).not.toBeNull()
  })

  it("reports a header error and no rows when a required column is missing", () => {
    const { rows, headerError } = parseRows([["name", "brand", "price"]], brands, models, existingProducts)
    expect(headerError).toMatch(/missing required column/)
    expect(rows).toEqual([])
  })
})
