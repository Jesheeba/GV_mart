import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { describe, expect, it, vi } from "vitest"
import { ChoiceSelect } from "./ChoiceSelect"
import { NO_SPINNER } from "@/lib/fieldWidth"

vi.mock("react-i18next", () => ({ useTranslation: () => ({ t: (k: string) => k }) }))

const OPTIONS = [
  { value: "own", label: "Own" },
  { value: "rental", label: "Rental" },
] as const

const html = (props: Partial<Parameters<typeof ChoiceSelect>[0]> = {}) =>
  renderToStaticMarkup(
    createElement(ChoiceSelect, { id: "ownership", label: "Ownership", value: "", options: OPTIONS, onChange: () => {}, ...props })
  )

describe("ChoiceSelect (either/or fields as dropdowns, 2026-11-26)", () => {
  it("required field: renders a <select> starting on a disabled 'Select…', nothing pre-selected", () => {
    const out = html()
    expect(out).toContain("<select")
    expect(out).toMatch(/<option value="" disabled="" selected="">common\.selectPlaceholder<\/option>/)
    expect(out).not.toMatch(/value="own" selected/)
    expect(out).not.toMatch(/value="rental" selected/)
  })

  it("optional field (water source): first option is an enabled 'Not set'", () => {
    const out = html({ optional: true })
    expect(out).toMatch(/<option value="" selected="">common\.notSet<\/option>/)
  })

  it("edit: shows the saved value as selected", () => {
    expect(html({ value: "rental" })).toMatch(/<option value="rental" selected="">Rental<\/option>/)
  })

  it("null/undefined saved value falls back to the placeholder instead of crashing", () => {
    expect(html({ value: null })).toMatch(/<option value="" disabled="" selected="">/)
    expect(html({ value: undefined })).toMatch(/<option value="" disabled="" selected="">/)
  })

  it("label is tied to the select, so focusChoice(id) and screen readers find it", () => {
    const out = html()
    expect(out).toContain('for="ownership"')
    expect(out).toContain('<select id="ownership"')
  })

  it("error: shown as an alert and linked via aria-describedby / aria-invalid", () => {
    const out = html({ error: "Choose own or rental" })
    expect(out).toContain('aria-invalid="true"')
    expect(out).toContain('aria-describedby="ownership-error"')
    expect(out).toContain('<p id="ownership-error" role="alert"')
    expect(out).toContain("Choose own or rental")
  })

  it("no error: no alert, no aria-invalid", () => {
    const out = html()
    expect(out).not.toContain("role=\"alert\"")
    expect(out).not.toContain("aria-invalid")
  })
})

describe("NO_SPINNER (water reading inputs without up/down arrows)", () => {
  it("hides the WebKit/Blink stepper and the Firefox one", () => {
    expect(NO_SPINNER).toContain("[&::-webkit-inner-spin-button]:appearance-none")
    expect(NO_SPINNER).toContain("[&::-webkit-outer-spin-button]:appearance-none")
    expect(NO_SPINNER).toContain("[appearance:textfield]")
  })
})
