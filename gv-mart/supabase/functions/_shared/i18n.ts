// Reads the SAME en.json/ta.json the React app's i18next instance uses
// (src/lib/i18n/*.json) — no separate translation source for the bot.
// This is a minimal dot-path + {{var}} reader, not full i18next: the
// runtime dependency itself is a browser-oriented library with no reason
// to run inside a Deno Edge Function, but the *strings* must stay singular.
import en from "../../../src/lib/i18n/en.json" with { type: "json" }
import ta from "../../../src/lib/i18n/ta.json" with { type: "json" }

export type WaLang = "en" | "ta"

const resources: Record<WaLang, unknown> = { en, ta }

function lookup(obj: unknown, path: string): string | undefined {
  const value = path.split(".").reduce<unknown>((acc, key) => {
    if (acc && typeof acc === "object" && key in (acc as Record<string, unknown>)) {
      return (acc as Record<string, unknown>)[key]
    }
    return undefined
  }, obj)
  return typeof value === "string" ? value : undefined
}

/** `t("en", "whatsapp.greeting.known", { name: "Muthu" })` — same key shape as the React app's `t()`, falls back to English then to the raw key if a translation is missing. */
export function t(lang: WaLang, key: string, vars?: Record<string, string | number>): string {
  const template = lookup(resources[lang], key) ?? lookup(resources.en, key) ?? key
  if (!vars) return template
  return Object.entries(vars).reduce((str, [k, v]) => str.replaceAll(`{{${k}}}`, String(v)), template)
}
