import { describe, expect, it } from "vitest"
import en from "./en.json"
import ta from "./ta.json"

/**
 * missing-i18n-keys (2026-11-26): a key the code asks for but the JSON lacks shows as raw text
 * (e.g. "leads.detail.addNote"). Guards both ways it happened: a key never added, and a duplicate
 * JSON key whose later copy silently discards the earlier block (leads.errors.budgetNonNegative).
 */
const sources = import.meta.glob(["/src/**/*.{ts,tsx}", "!/src/**/*.test.{ts,tsx}"], { query: "?raw", import: "default", eager: true }) as Record<string, string>
const rawJson = import.meta.glob("./*.json", { query: "?raw", import: "default", eager: true }) as Record<string, string>

function lookup(dict: unknown, key: string): unknown {
  return key.split(".").reduce<unknown>((o, k) => (o && typeof o === "object" ? (o as Record<string, unknown>)[k] : undefined), dict)
}
const PLURALS = ["", "_one", "_other"]
const has = (dict: unknown, key: string) => PLURALS.some((s) => typeof lookup(dict, key + s) === "string")

/** Literal keys passed to t(), plus every dotted string in lib/validation (zod messages are i18n keys there). */
function referencedKeys(): Map<string, string> {
  const out = new Map<string, string>()
  const call = /\bt\(\s*["'`]([a-z]\w*(?:\.\w+)+)["'`]/g
  const literal = /["'`]([a-z]\w*(?:\.\w+)+)["'`]/g
  for (const [file, text] of Object.entries(sources)) {
    const re = file.startsWith("/src/lib/validation/") ? literal : call
    for (const m of text.matchAll(re)) if (!out.has(m[1])) out.set(m[1], file)
  }
  return out
}

function duplicateKeys(file: string): string[] {
  const dups: string[] = []
  // JSON.parse keeps only the last copy of a duplicate key, so walk the raw text and track keys per object.
  const stack: Set<string>[] = []
  const token = /"((?:[^"\\]|\\.)*)"\s*(:)?|[{}]/g
  for (const m of rawJson[file].matchAll(token)) {
    if (m[0] === "{") stack.push(new Set())
    else if (m[0] === "}") stack.pop()
    else if (m[2]) {
      const seen = stack[stack.length - 1]
      if (seen.has(m[1])) dups.push(`${m[1]} (offset ${m.index})`)
      seen.add(m[1])
    }
  }
  return dups
}

describe("i18n keys are complete", () => {
  const refs = referencedKeys()

  it("found the referenced keys (scanner sanity)", () => {
    expect(refs.size).toBeGreaterThan(500)
    expect(refs.has("leads.detail.addNote")).toBe(true)
    expect(refs.has("automation.errors.triggerRequired")).toBe(true)
  })

  it("every key used in code exists in English", () => {
    expect([...refs].filter(([k]) => !has(en, k)).map(([k, f]) => `${k} (${f})`)).toEqual([])
  })

  it("every key used in code exists in Tamil", () => {
    expect([...refs].filter(([k]) => !has(ta, k)).map(([k, f]) => `${k} (${f})`)).toEqual([])
  })

  it.each(["./en.json", "./ta.json"])("%s has no duplicate keys (a later copy would silently drop the earlier one)", (file) => {
    expect(duplicateKeys(file)).toEqual([])
  })

  it("the rescued budget message is reachable", () => {
    expect(lookup(en, "leads.errors.budgetNonNegative")).toBe("Budget must be zero or more")
    expect(has(ta, "leads.errors.budgetNonNegative")).toBe(true)
  })
})
