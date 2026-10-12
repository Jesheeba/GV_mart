import { describe, expect, it } from "vitest"
import { formatIstDate, formatIstSlot, formatRupees, shortRef } from "./wa-event-format"
import { duplicateTemplateNames, mapWasiTemplateList } from "./wasi-templates"

describe("wa-event-format", () => {
  it("shortRef is the first 8 hex chars, upper case", () => {
    expect(shortRef("675663a5-4200-4056-940f-ebc52e2b6fde")).toBe("675663A5")
    expect(shortRef(null)).toBe("")
  })
  it("formats IST slots independent of the machine timezone", () => {
    expect(formatIstSlot("2026-10-12T10:00:00Z")).toBe("12 Oct, 3:30 PM")
    expect(formatIstSlot("2026-10-12T18:30:00Z")).toBe("13 Oct, 12:00 AM")
    expect(formatIstSlot("2026-10-12T06:30:00Z")).toBe("12 Oct, 12:00 PM")
    expect(formatIstSlot("bad")).toBeNull()
    expect(formatIstDate("2026-10-12T20:00:00Z")).toBe("13 Oct 2026")
  })
  it("formats rupees with Indian grouping", () => {
    expect(formatRupees(1234)).toBe("Rs 1,234")
    expect(formatRupees("1234567")).toBe("Rs 12,34,567")
    expect(formatRupees(99.5)).toBe("Rs 99.50")
    expect(formatRupees(null)).toBeNull()
    expect(formatRupees("abc")).toBeNull()
  })
})

describe("mapWasiTemplateList", () => {
  const sample = [
    { name: "shipping_update", language: "en_US", category: "Utility", status: "approved", header_type: null, body_param_examples: { name: "Riyaz" }, orphaned_at: null },
    { name: "invoice_document", language: "en_US", category: "Utility", status: "approved", header_type: "DOCUMENT", body_param_examples: { customer_name: "A", invoice_date: "d", invoice_number: "n" } },
    { name: "hello_world", language: "en_US", category: "Utility", status: "approved", header_type: "TEXT", body_param_examples: null },
    { name: "gone", language: "en_US", status: "approved", orphaned_at: "2026-10-01T00:00:00Z" },
    { name: "po_quote_request_doc_v3", language: "en_US", status: "approved", header_type: "DOCUMENT" },
    { name: "po_quote_request_doc_v3", language: "en", status: "approved", header_type: "DOCUMENT" },
    { name: "", status: "approved" },
  ]
  it("maps param keys, header type and lowercases status", () => {
    const rows = mapWasiTemplateList(sample)
    const ship = rows.find((r) => r.wasi_name === "shipping_update")!
    expect(ship.param_keys).toEqual(["name"])
    expect(ship.header_type).toBeNull()
    expect(rows.find((r) => r.wasi_name === "invoice_document")?.header_type).toBe("DOCUMENT")
    expect(rows.find((r) => r.wasi_name === "invoice_document")?.param_keys).toEqual(["customer_name", "invoice_date", "invoice_number"])
    expect(rows.find((r) => r.wasi_name === "hello_world")?.param_keys).toEqual([])
  })
  it("an orphaned template is never approved, and nameless entries are dropped", () => {
    const rows = mapWasiTemplateList(sample)
    expect(rows.find((r) => r.wasi_name === "gone")?.status).toBe("orphaned")
    expect(rows.some((r) => r.wasi_name === "")).toBe(false)
  })
  it("finds names that exist in more than one language (Wasi picks arbitrarily)", () => {
    expect(duplicateTemplateNames(mapWasiTemplateList(sample))).toEqual(["po_quote_request_doc_v3"])
  })
  it("tolerates a wrapped or empty payload", () => {
    expect(mapWasiTemplateList({ data: sample.slice(0, 1) })).toHaveLength(1)
    expect(mapWasiTemplateList(null)).toEqual([])
  })
})
