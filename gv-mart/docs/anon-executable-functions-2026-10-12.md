# Anon-executable `public` functions, after the 2026-10-12 revoke (report only)

Live catalog after migration `20261015120000_revoke_unguarded_write_functions`: **83** non-trigger functions are still executable by `anon` (was 93; ten write functions were revoked). "Executable by anon" here comes from the default PUBLIC grant. Nothing in this list was changed.

## A. Safe by design - must stay executable (13)
Called from RLS policies and helper functions as the invoking role, so the invoking role needs EXECUTE. Each returns NULL/false/empty for anon.
`current_role`, `current_org_id`, `current_customer_id`, `current_technician_id`, `current_technician_is_active`, `is_master`, `is_ops_staff`, `is_staff`, `is_sales_staff`, `customer_owns_appointment`, `customer_sees_technician`, `customer_sees_technician_profile`, `is_technician_customer`.

## B. Safe, identity-gated; anon EXECUTE is only hygiene (59)
Each raises for anon at an identity or role check before reading or writing anything (customer / technician / active staff, organisation match).
* Customer app: `book_service_ticket`, `request_callback`, `submit_customer_enquiry`, `submit_customer_rating`, `register_product_via_qr`, `renew_amc_plan`, `delete_my_address`, `list_my_tickets_filtered`, `link_customer_google_account` (needs `auth.uid()`).
* Technician app: `generate_visit_otp`, `verify_visit_otp`, `get_visit_payment_state`, `record_upi_payment`, `record_payment_proof`, `record_technician_arrival_address`, `create_service_invoice` (2 overloads), `submit_rating`, `log_technician_google_review`, `mark_google_review_clicked`, `technician_respond_shift_end_prompt`, `sell_amc_plan_onsite`, `confirm_spare_handover`.
* Staff (guard is `is_master()` / `is_ops_staff()` / `is_sales_staff()` / `is_staff()`, now strict booleans after F-07): `create_sale`, `sell_amc_plan`, `create_rental`, `mark_rental_returned`, `record_additional_payment`, `award_referral_points`, `create_complaint_ticket`, `cancel_service_ticket`, `delete_service_ticket`, `assign_ticket_technician`, `auto_assign_ticket`, `complete_appointment`, `admin_override_visit_completion`, `admin_sign_spare_handover`, `create_spare_handover`, `create_spare_return`, `log_confirmed_availability`, `create_purchase_order` (now definer, see migration), `approve_purchase_order`, `update_po_items_and_approve`, `mark_po_paid`, `log_purchase_quote_reply`, `mark_quote_supplier_no_response`, `resolve_purchase_quote_requests`, `create_bill_entry`, `compute_salary`, `compute_incentives`, `reward_candidates`, `technician_kpi_summary`, `refresh_amc_statuses`, `refresh_operational_alerts`, `set_item_standard_time`.
* Invoker functions bound by RLS: `create_quotation`, `set_primary_member`, `_detect_ticket_type` (also called by the browser, so only anon should lose it).
* `_wa_numbers_valid` (F-08, pure, used by a CHECK constraint evaluated as the writing role).
Optional hygiene (not done, needs your OK): `revoke execute ... from public, anon` on all of B except where listed as called by the browser anonymously (none are); `authenticated` keeps its grant. Effect: anon gets a clean "permission denied" instead of a function-level refusal.

## C. Needs a guard (2)
* `resolve_stale_bookings(p_org_id)` - only an organisation match: any signed-in member of the organisation (customer or technician) can trigger the bulk "resolve stale bookings" job for the whole organisation. Needs `is_staff()` or a restriction to the caller's own bookings; the customer app calls it on load, so it needs a small design decision.
* `get_technician_public_stats(p_technician_id)` - organisation match only; intended to be visible to customers who met the technician. Low risk, listed for completeness (could be limited to technicians the caller has had a ticket with).

## D. Needs a revoke (9)
No browser caller; callers are definer functions or service-role Edge Functions (verified by search). Read-only or pure, so lower priority than the ten already revoked.
`wa_get_business_info`, `wa_get_emi_info`, `wa_get_products_by_category`, `wa_supplier_latest_sent_po` (service-role bot only), `technician_installation_count` (called by `compute_incentives`), `_next_ticket_available_for_technician` (called by `technician_respond_shift_end_prompt`), `_customer_exemption_blocks`, `_derive_payment_status`, `_largest_free_window` (pure helpers called from definer functions).

## E. Already revoked on 2026-10-12 (10, `20261015120000`)
`run_rental_billing`, `advance_recurring_tasks`, `open_monthly_quote_requests`, `_create_po_from_winning_quote`, `_create_po_payment_reminder_task`, `_auto_assign_ticket_internal`, `_resolve_purchase_quote_requests_core`, `wa_resolve_purchase_quote_requests`, `wa_escalate_overdue_po_payment_reminders`, `_sale_create_line_invoice`. EXECUTE now: owner and `service_role` only. Previous ACLs: `Desktop\GV_mart_acl_backup_2026-10-12_unguarded_write_functions.json`.
