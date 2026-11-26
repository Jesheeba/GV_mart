import type { CrudFieldDef, CrudFieldOption } from "@/components/shared/EntityCrudTable"

/** Pure form helpers for EntityCrudTable, kept here so they can be unit-tested without rendering it. */

export function resolveOptions(field: CrudFieldDef, values: Record<string, string>): CrudFieldOption[] {
  if (!field.options) return []
  return typeof field.options === "function" ? field.options(values) : field.options
}

/**
 * A select whose own options include "" (e.g. "Any product", "—") treats empty as a real choice. Every
 * other select shows a disabled "Select…" placeholder and must be picked before saving (choice-no-preselect).
 */
export function selectNeedsChoice(field: CrudFieldDef, values: Record<string, string>): boolean {
  return field.type === "select" && !resolveOptions(field, values).some((o) => o.value === "")
}

/**
 * Values a brand-new row starts with: empty ("Select…" for a select) unless the field sets `defaultValue`,
 * which is reserved for status-like fields whose DB default matches (e.g. is_active "true"). Replaces the
 * old "select starts at its first option" rule, which pre-chose real data for staff.
 */
export function initialFormValues(fields: CrudFieldDef[]): Record<string, string> {
  return Object.fromEntries(fields.map((f) => [f.key, f.defaultValue ?? ""]))
}

/** First client-side validation failure (field key + message), or null. Runs before onCreate/onUpdate. */
export function validateFields(
  fields: CrudFieldDef[],
  values: Record<string, string>,
  t: (key: string, opts?: Record<string, unknown>) => string
): { key: string; message: string } | null {
  for (const f of fields) {
    if (f.readOnly) continue
    const raw = values[f.key] ?? ""
    const value = raw.trim()
    const fail = (message: string) => ({ key: f.key, message })
    if (value === "" && (f.required || selectNeedsChoice(f, values))) {
      return fail(t("common.errors.fieldRequired", { field: f.label }))
    }
    if (value === "") continue
    if (f.type === "number") {
      const n = Number(value)
      if (Number.isNaN(n)) return fail(t("common.errors.fieldMustBeNumber", { field: f.label }))
      if (f.min != null && n < f.min) return fail(t("common.errors.fieldMin", { field: f.label, min: f.min }))
      if (f.max != null && n > f.max) return fail(t("common.errors.fieldMax", { field: f.label, max: f.max }))
    }
    if (f.type === "email" && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
      return fail(t("common.errors.fieldInvalid", { field: f.label }))
    }
    if (f.type === "url") {
      try {
        new URL(value)
      } catch {
        return fail(t("common.errors.fieldInvalid", { field: f.label }))
      }
    }
    if (f.pattern && !new RegExp(`^(?:${f.pattern})$`).test(value)) {
      return fail(f.patternMessage ?? t("common.errors.fieldInvalid", { field: f.label }))
    }
  }
  return null
}
