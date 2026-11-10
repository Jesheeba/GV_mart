import { describe, expect, it } from "vitest"
import { parseCsv, toCsv } from "./csv"

describe("parseCsv", () => {
  it("parses a plain comma-separated file with a header row", () => {
    const rows = parseCsv("name,price\nFoo,100\nBar,200")
    expect(rows).toEqual([
      ["name", "price"],
      ["Foo", "100"],
      ["Bar", "200"],
    ])
  })

  it("handles quoted fields containing commas", () => {
    const rows = parseCsv('name,note\n"Foo, Bar",hello')
    expect(rows).toEqual([
      ["name", "note"],
      ["Foo, Bar", "hello"],
    ])
  })

  it("handles escaped double quotes inside a quoted field", () => {
    const rows = parseCsv('name\n"Say ""hi"""')
    expect(rows).toEqual([["name"], ['Say "hi"']])
  })

  it("handles CRLF line endings", () => {
    const rows = parseCsv("a,b\r\n1,2\r\n")
    expect(rows).toEqual([
      ["a", "b"],
      ["1", "2"],
    ])
  })

  it("drops a trailing blank line but keeps a trailing unterminated row", () => {
    const rows = parseCsv("a,b\n1,2\n")
    expect(rows).toEqual([
      ["a", "b"],
      ["1", "2"],
    ])
  })
})

describe("toCsv", () => {
  it("quotes a field containing a comma", () => {
    expect(toCsv([["Foo, Bar", "100"]])).toBe('"Foo, Bar",100')
  })

  it("round-trips through parseCsv", () => {
    const original = [
      ["name", "note"],
      ["Aquafresh RO", 'Say "hi", ok'],
    ]
    const csv = toCsv(original)
    expect(parseCsv(csv)).toEqual(original)
  })
})
