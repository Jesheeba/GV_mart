// Product Lifecycle & Automated Service Reminder System — W1 (masters form).
// Contract types shared with the lead's RPC/table wiring — names must match
// exactly (see FEATURE_PRODUCT_LIFECYCLE build-out).

export type LifetimeUnit = "months" | "years"

export interface ProductLifecycleConfig {
  id: string
  productId: string
  lifetimeValue: number
  lifetimeUnit: LifetimeUnit
  isActive: boolean
}

export interface ProductSpareSchedule {
  id: string
  productId: string
  spareId: string | null
  label: string
  intervalValue: number
  intervalUnit: LifetimeUnit
  isActive: boolean
}

/** One preview row returned by the apply_updated_schedule_preview RPC. */
export interface ApplyUpdatedSchedulePreviewRow {
  installed_product_id: string
  customer_id: string
  parts_to_add: number
}

// ── Form-side validation ────────────────────────────────────────────────
// Pure, dependency-free so it can be unit-tested without mocking Supabase
// (see productLifecycle.validation.test.ts).

/** A positive integer — used for both lifetimeValue and intervalValue. */
export function isPositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0
}

export interface LifetimeFormValues {
  lifetimeValue: number
  lifetimeUnit: LifetimeUnit
}

export interface LifetimeValidationResult {
  valid: boolean
  errors: { lifetimeValue?: string }
}

/** Validates the single lifetime input: integer, > 0. */
export function validateLifetime(values: LifetimeFormValues): LifetimeValidationResult {
  const errors: LifetimeValidationResult["errors"] = {}
  if (!isPositiveInteger(values.lifetimeValue)) {
    errors.lifetimeValue = "lifetimeValueInvalid"
  }
  return { valid: Object.keys(errors).length === 0, errors }
}

export interface SpareScheduleFormRow {
  spareId: string | null
  label: string
  intervalValue: number
  intervalUnit: LifetimeUnit
}

export interface SpareScheduleRowErrors {
  label?: string
  intervalValue?: string
}

export interface SpareScheduleValidationResult {
  valid: boolean
  rowErrors: SpareScheduleRowErrors[]
}

/**
 * Validates every spare-schedule repeater row: label required (non-empty
 * after trim) and intervalValue a positive integer. Duplicate labels across
 * rows on the same product are deliberately allowed (not deduped) per spec.
 */
export function validateSpareSchedules(rows: SpareScheduleFormRow[]): SpareScheduleValidationResult {
  const rowErrors = rows.map((row): SpareScheduleRowErrors => {
    const errors: SpareScheduleRowErrors = {}
    if (!row.label.trim()) {
      errors.label = "labelRequired"
    }
    if (!isPositiveInteger(row.intervalValue)) {
      errors.intervalValue = "intervalValueInvalid"
    }
    return errors
  })
  const valid = rowErrors.every((e) => Object.keys(e).length === 0)
  return { valid, rowErrors }
}
