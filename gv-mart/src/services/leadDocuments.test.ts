import { describe, expect, it } from "vitest"
import { LEAD_DOCUMENT_MAX_BYTES, validateLeadDocument } from "./leadDocuments"

function fakeFile(type: string, size: number): File {
  return { type, size } as File
}

describe("validateLeadDocument", () => {
  it("accepts an allowed type within the size limit", () => {
    expect(validateLeadDocument(fakeFile("application/pdf", 1024))).toBeNull()
  })

  it("rejects a disallowed MIME type", () => {
    expect(validateLeadDocument(fakeFile("application/zip", 1024))).toBe("unsupportedType")
  })

  it("rejects a file over the size limit", () => {
    expect(validateLeadDocument(fakeFile("image/png", LEAD_DOCUMENT_MAX_BYTES + 1))).toBe("tooLarge")
  })

  it("accepts a file exactly at the size limit", () => {
    expect(validateLeadDocument(fakeFile("image/jpeg", LEAD_DOCUMENT_MAX_BYTES))).toBeNull()
  })
})
