# Feature: missing-i18n-keys (2026-11-26)

Status: SHIPPED 2026-11-26, merged to main c32083d. No DB change.

## Purpose
- Screens showed raw key text (e.g. "leads.detail.addNote") where an English/Tamil string was missing.

## What was wrong
- 37 keys used in code (t() calls and zod messages in lib/validation) were missing from both en.json and ta.json. Affected: automation errors, purchase errors, returns errors, report date-range errors, customer-app callback errors, workspace/campaign errors, lead errors, `common.confirm`, `quotations.origin.direct`, `reports.staff`, lead note sheet, technician expense messages.
- Both JSON files had duplicate keys from merges: `leads.errors` ×3, `leads.edit` ×2, `auth.useDifferentAccount` ×2. JSON.parse keeps only the last copy, so `leads.errors.budgetNonNegative` (first copy) never loaded, and the Lead details budget error showed the raw key.
- Tamil lacked 3 technician sync labels (attendance check-out, review link click, AMC sale), allowlisted in parity.test.ts.

## Fix
- Removed the duplicate copies (the identical ones were dropped; budgetNonNegative was merged into the kept `leads.errors`). Added the 37 keys in en + ta and the 3 Tamil labels, then emptied the parity allowlist.
- Not i18n keys, so left alone: dotted DB column strings such as `customers.is_test` and `technicians.zone`.

## Acceptance criteria
1. Every literal key in t("…") and every dotted string in lib/validation exists in en and ta.
2. Neither JSON file has a duplicate key at any level.
3. en/ta parity holds with no allowlist.
4. Wording reuses existing phrasing where it exists (e.g. technicianLeave.notAvailableYet / valuesKept).

## Impact map
- en.json and ta.json only. Values of existing keys are unchanged. The only newly visible text is budgetNonNegative, which now loads.
