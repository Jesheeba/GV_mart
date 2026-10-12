// Pure mapper from Wasi's GET /api/v1/templates response to our mirror rows (whatsapp_wasi_templates).
// No Deno / Supabase imports, so vitest can use it. See docs/plan-dispatcher-fix.md (a) and (f).
//
// Verified shape (2026-10-12): an array of objects with
//   id, client_id, name, category, status, body, language, rejection_reason, header_type, header_content, footer_text,
//   buttons, body_param_examples, auth_options, meta_template_id, orphaned_at
// `body_param_examples` is an object whose KEYS are the exact param names a send must supply.

export type WasiTemplateMirrorRow = {
  wasi_name: string
  language: string
  category: string | null
  status: string
  header_type: string | null
  param_keys: string[]
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null
}

export function mapWasiTemplateList(payload: unknown): WasiTemplateMirrorRow[] {
  const list = Array.isArray(payload) ? payload : (asRecord(payload)?.data as unknown[] | undefined) ?? (asRecord(payload)?.templates as unknown[] | undefined) ?? []
  const out: WasiTemplateMirrorRow[] = []
  for (const item of list) {
    const t = asRecord(item)
    if (!t || typeof t.name !== "string" || t.name === "") continue
    const examples = asRecord(t.body_param_examples)
    const orphaned = typeof t.orphaned_at === "string" && t.orphaned_at !== ""
    out.push({
      wasi_name: t.name,
      language: typeof t.language === "string" && t.language ? t.language : "en_US",
      category: typeof t.category === "string" ? t.category : null,
      // A template Wasi no longer has (orphaned) must never count as approved.
      status: orphaned ? "orphaned" : String(t.status ?? "unknown").toLowerCase(),
      header_type: typeof t.header_type === "string" && t.header_type ? t.header_type.toUpperCase() : null,
      param_keys: examples ? Object.keys(examples) : [],
    })
  }
  return out
}

/** When one template name exists in several languages Wasi picks arbitrarily (their known bug), so such a name must
 * never be used for a send. Returns the duplicated names. */
export function duplicateTemplateNames(rows: WasiTemplateMirrorRow[]): string[] {
  const seen = new Map<string, number>()
  for (const r of rows) seen.set(r.wasi_name, (seen.get(r.wasi_name) ?? 0) + 1)
  return [...seen.entries()].filter(([, n]) => n > 1).map(([name]) => name)
}
