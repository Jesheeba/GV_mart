# Phase 0 live read-only findings, 2026-10-12

Read-only queries against project `fsunrjithwcjtsutsgea` (Management API). Nothing was changed by these checks. The original a-i lettering of the review's live checks was not available in the repository, so every item the docs list as "unverified" was checked.

## Auth configuration (live)
`jwt_exp` 3600 s; refresh-token rotation on (reuse interval 10 s); no session timebox or inactivity timeout; `disable_signup` **false**; `password_min_length` **6**; `site_url` **http://localhost:3000**; Google provider disabled; email provider on, autoconfirm off.

## Helpers and `current_role()`
* `current_role()` = `select role from profiles where id = auth.uid()` (definer, `search_path=public`).
* `is_master()` = `current_role() = 'master'`, `is_ops_staff()` = `current_role() in ('master','operation_admin')`: both **NULL**, not false, when the role is NULL.
* `is_staff()` / `is_sales_staff()` read `profiles` directly (sales_admin must be active; master and operation_admin did not need to be).
* ~40 definer functions guard with `if not public.is_master()/is_ops_staff()/is_sales_staff()/is_staff() then raise`. Guards on a NULL helper fail open.

## Everything that changes if `current_role()` returns NULL
Functions with a direct call: `is_master`, `is_ops_staff`, `_lead_resolve_scope`, `_lead_set_followup_allowed`, `assign_lead`, `followup_counts`.
Policies with a direct call: `notifications_select_own_role`, `notifications_update_own_role`, `settings_select_org` (the only `IS DISTINCT FROM` pattern).
Policies with `org_id = current_org_id()` and no role helper: 34, all SELECT-only (catalogues, plus `meeting_logs`, `meeting_issues`, `automation_flows`, `payment_settings`, `lead_*`, `product_*`).
Policies with no identity helper at all: 0. Tables without RLS: 0.

## Definer functions
206 SECURITY DEFINER functions in `public`, all with `search_path=public` (none empty, none with `pg_temp` last).

## Anon-executable public functions (93, all through the default PUBLIC grant)
* **Unsafe (definer, no guard, writes; need only the public key and an organisation id):** `run_rental_billing`, `advance_recurring_tasks`, `open_monthly_quote_requests`, `_create_po_from_winning_quote`, `_create_po_payment_reminder_task`, `_auto_assign_ticket_internal`, `_resolve_purchase_quote_requests_core`, `wa_resolve_purchase_quote_requests`, `wa_escalate_overdue_po_payment_reminders`, `_sale_create_line_invoice`.
* **Unsafe read (no guard):** `wa_get_business_info`, `wa_get_emi_info`, `wa_get_products_by_category`, `wa_supplier_latest_sent_po`, `technician_installation_count`, `_next_ticket_available_for_technician`.
* **Safe (identity or role guard raises for anon), anon EXECUTE unnecessary:** `create_sale`, `sell_amc_plan` (staff guard + organisation match), `sell_amc_plan_onsite` (technician), `renew_amc_plan` (customer), and the other customer/technician/staff RPCs. `resolve_stale_bookings` has only an organisation check (low).
* **Must stay executable (called from RLS policies as the invoking role):** `current_role`, `current_org_id`, `current_customer_id`, `current_technician_id`, `current_technician_is_active`, `is_master`, `is_ops_staff`, `is_staff`, `is_sales_staff`, `customer_owns_appointment`, `customer_sees_technician`, `customer_sees_technician_profile`, `is_technician_customer`.
Callers of the unsafe internal functions: other definer functions, `wa-scheduled-tasks`, `generate-quote-pdf` and the WhatsApp bot (service-role Edge Functions); none from the browser client.

## Other
* F-06 was live: `guard_profile_privileged_columns` returns early for any master (organisation check only).
* `audit_log`: 2370 rows; UPDATE/DELETE/TRUNCATE were granted to anon/authenticated/service_role; org CASCADE; actor SET NULL; a `set_updated_at` trigger.
* `whatsapp_outbox`: staff INSERT policy for any `to_mobile`; no triggers; `send_whatsapp_stub` INVOKER, EXECUTE to PUBLIC/anon/authenticated. Only staff-side caller: `create_purchase_order`.
* Other sessions' throwaway organisations exist (`__TEST_reports_live_*`, `__TEST_ GV Mart 2026-10-12`); not touched.
