import { describe, expect, it } from "vitest"
import type { TFunction } from "i18next"
import { leadKindLabel, leadProductTypeLabel } from "./lead-lists"
import type { LeadKindRow, LeadProductTypeRow } from "@/services/masters"

// Minimal stand-in for i18next's t: resolves a known key, else the defaultValue.
const dict: Record<string, string> = { "leads.kind.spare": "Spare (i18n)", "masters.categories.ro": "RO (i18n)" }
const t = ((key: string, opts?: { defaultValue?: string }) => dict[key] ?? opts?.defaultValue ?? key) as unknown as TFunction

const base = { id: "i", org_id: "o", is_active: true, created_at: "", updated_at: "" }
const kinds: LeadKindRow[] = [
  { ...base, key: "spare", label: "Spare", label_ta: null, is_system: true },
  { ...base, key: "warranty", label: "Warranty", label_ta: "உத்தரவாதம்", is_system: false },
  { ...base, key: "recall", label: "Recall", label_ta: null, is_system: false },
]
const types: LeadProductTypeRow[] = [
  { ...base, key: "ro", label: "RO / Water Purifier", label_ta: null, is_system: true },
  { ...base, key: "multigrade", label: "Multigrade", label_ta: "மல்டிகிரேட்", is_system: false },
]

describe("lead list labels", () => {
  it("built-in kinds use the translation so Tamil always works", () => {
    expect(leadKindLabel("spare", kinds, t, "ta")).toBe("Spare (i18n)")
  })
  it("custom kinds use the master label, the Tamil label on the Tamil UI", () => {
    expect(leadKindLabel("warranty", kinds, t, "en")).toBe("Warranty")
    expect(leadKindLabel("warranty", kinds, t, "ta")).toBe("உத்தரவாதம்")
    expect(leadKindLabel("warranty", kinds, t, "ta-IN")).toBe("உத்தரவாதம்")
  })
  it("a custom kind without a Tamil label falls back to the English label", () => {
    expect(leadKindLabel("recall", kinds, t, "ta")).toBe("Recall")
  })
  it("an unknown or deleted key shows the key itself", () => {
    expect(leadKindLabel("gone", kinds, t, "en")).toBe("gone")
    expect(leadKindLabel("gone", undefined, t, "en")).toBe("gone")
  })
  it("product types: built-ins reuse the category translation, custom use the master label", () => {
    expect(leadProductTypeLabel("ro", types, t, "en")).toBe("RO (i18n)")
    expect(leadProductTypeLabel("multigrade", types, t, "en")).toBe("Multigrade")
    expect(leadProductTypeLabel("multigrade", types, t, "ta")).toBe("மல்டிகிரேட்")
  })
})
