import { describe, expect, it } from "vitest"
import { createElement } from "react"
import { renderToStaticMarkup } from "react-dom/server"
import { UseMyLocationButton } from "./UseMyLocationButton"

/**
 * Customer-side discoverability fix: the labelled "Use my current location" button must be a
 * full-width, >=44px touch target on a phone -- not the small icon-only corner control that was
 * easy to miss. Rendered with react-dom/server (plain Node, no jsdom/testing-library needed --
 * this project has neither installed, and vitest.config.ts only runs plain .test.ts files with
 * no JSX plugin, hence createElement here instead of JSX) so this is a real render, not a
 * string match on the source file.
 */
describe("UseMyLocationButton (mobile-width check)", () => {
  it("is full width (w-full) with an at-least-44px touch target (h-11 = 44px)", () => {
    const html = renderToStaticMarkup(
      createElement(UseMyLocationButton, { locating: false, label: "Use my current location", locatingLabel: "Finding your location…", onClick: () => {} })
    )
    expect(html).toMatch(/class="[^"]*\bw-full\b[^"]*"/)
    expect(html).toMatch(/class="[^"]*\bh-11\b[^"]*"/) // h-11 = 2.75rem = 44px
  })

  it("shows the given label when idle", () => {
    const html = renderToStaticMarkup(
      createElement(UseMyLocationButton, { locating: false, label: "Use my current location", locatingLabel: "Finding your location…", onClick: () => {} })
    )
    expect(html).toContain("Use my current location")
    expect(html).not.toContain("Finding your location")
  })

  it("shows the locating label and is disabled while busy", () => {
    const html = renderToStaticMarkup(
      createElement(UseMyLocationButton, { locating: true, label: "Use my current location", locatingLabel: "Finding your location…", onClick: () => {} })
    )
    expect(html).toContain("Finding your location")
    expect(html).not.toContain("Use my current location")
    expect(html).toMatch(/disabled=""|disabled/)
  })
})
