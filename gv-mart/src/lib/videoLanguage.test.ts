import { describe, expect, it } from "vitest"
import { toVideoLanguage, VIDEO_LANGUAGES } from "./videoLanguage"

describe("toVideoLanguage", () => {
  it("keeps en and ta", () => {
    expect(toVideoLanguage("en")).toBe("en")
    expect(toVideoLanguage("ta")).toBe("ta")
  })
  it("maps the any-language form value and unknown values to null", () => {
    expect(toVideoLanguage("")).toBeNull()
    expect(toVideoLanguage(null)).toBeNull()
    expect(toVideoLanguage(undefined)).toBeNull()
    expect(toVideoLanguage("EN")).toBeNull()
    expect(toVideoLanguage("fr")).toBeNull()
  })
  it("lists exactly the two languages the database accepts", () => {
    expect([...VIDEO_LANGUAGES]).toEqual(["en", "ta"])
  })
})
