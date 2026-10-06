// Pure helpers (no Deno / network / Supabase imports, so vitest can import them)
// that turn a failed Wasi send into the text stored in whatsapp_outbox.error.
//
// Why: the outbox used to keep only a one-line summary ("409: unknown_error"),
// and the raw response body only went to the function's console log — so a
// persistent Wasi rejection needed log digging to understand. This keeps a
// short, CLEANED copy of Wasi's actual response next to the summary.
//
// Everything stored here is passed through redactWasiText first: credentials
// must never land in a table staff can read, and phone numbers are masked the
// same way the rest of the app logs them (first 2 + last 2 digits).

export const WASI_ERROR_BODY_MAX_CHARS = 500

/** Response headers worth keeping — nothing that can carry credentials. */
const HEADER_ALLOWLIST = ["content-type", "x-request-id", "request-id", "retry-after"] as const

const REDACTED = "[redacted]"

/** Masks the middle of a phone-length digit run, keeping the first 2 and last 2. */
function maskDigits(run: string): string {
  return run.slice(0, 2) + "*".repeat(Math.max(run.length - 4, 0)) + run.slice(-2)
}

export function redactWasiText(input: string): string {
  let s = input

  // Authorization-style credentials.
  s = s.replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}/gi, `$1 ${REDACTED}`)

  // key/value pairs naming a secret — JSON ("api_key":"…"), query-string or
  // header-ish (token=…, secret: …). Value runs to the next quote, comma,
  // ampersand, whitespace or closing brace/bracket.
  s = s.replace(
    /(["']?(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|auth[_-]?token|token|secret|client[_-]?secret|password|authorization|x-api-key)["']?\s*[:=]\s*)(["']?)[^"'\s,&}\]]+\2/gi,
    `$1$2${REDACTED}$2`
  )

  // JWT-shaped tokens (three base64url segments) and long opaque tokens /
  // hex keys that appear bare, without a key name in front of them.
  s = s.replace(/\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b/g, REDACTED)
  // UUIDs and Wasi/WhatsApp message ids ("wamid.…") are identifiers support will ask for, not secrets — kept.
  s = s.replace(
    /(?<!wamid\.)\b(?![0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]{32,}\b/g,
    REDACTED
  )
  s = s.replace(/\b[a-f0-9]{32,}\b/gi, REDACTED)

  // Phone numbers: 10–15 digit runs, optionally behind a '+'.
  s = s.replace(/\+?\d{10,15}/g, (m) => (m.startsWith("+") ? "+" : "") + maskDigits(m.replace("+", "")))

  return s
}

function truncate(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s
}

/** Minimal headers shape so tests can pass a Map/plain object without a Fetch Response. */
export type HeadersLike = { get(name: string): string | null }

/**
 * `summary` is the existing short form ("409: unknown_error"); it is kept as
 * the first segment so anything that matches on it keeps working.
 * Result shape: `<summary> | body: <cleaned raw body, ≤500 chars> | headers: <allowlisted>`
 * (the body / headers segments are omitted when empty).
 */
export function buildWasiErrorDetail(summary: string, rawBody: string, headers?: HeadersLike | null): string {
  const parts = [summary]

  const body = redactWasiText(rawBody ?? "").replace(/\s+/g, " ").trim()
  if (body) parts.push(`body: ${truncate(body, WASI_ERROR_BODY_MAX_CHARS)}`)

  if (headers) {
    const kept: string[] = []
    for (const name of HEADER_ALLOWLIST) {
      const value = headers.get(name)
      if (value) kept.push(`${name}=${truncate(redactWasiText(value).replace(/\s+/g, " ").trim(), 100)}`)
    }
    if (kept.length > 0) parts.push(`headers: ${kept.join("; ")}`)
  }

  return parts.join(" | ")
}
