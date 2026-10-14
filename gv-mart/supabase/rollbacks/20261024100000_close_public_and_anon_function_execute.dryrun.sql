-- DRY RUN for 20261024100000_close_public_and_anon_function_execute: lists every function the migration will touch and what it will do.
-- Read-only. Run it immediately before GO APPLY; any row marked "UNLISTED" was created after the audit
-- (for example by the AMC migration) and gets the same rule: PUBLIC and anon closed, authenticated kept only if it had it.
with trigger_group(name) as (values
    ('_attendance_compute_status')
    ,('_auto_draft_purchase_order')
    ,('_gift_create_inventory_row')
    ,('_gift_log_decrement_stock')
    ,('_milestone_invoice_notify')
    ,('_milestone_ticket_notify')
    ,('_milestone_visit_notify')
    ,('_notify_customer_ticket_milestone')
    ,('_notify_customer_visit_started')
    ,('_notify_task_assigned')
    ,('_notify_technician_low_stock')
    ,('_on_attendance_present_assign_backlog')
    ,('_po_task_completed_marks_paid')
    ,('_service_tickets_derive_skill_and_duration')
    ,('_technicians_deactivate_clears_duty')
    ,('audit_master_change')
    ,('audit_profile_changes')
    ,('enforce_customer_members_limit')
    ,('guard_appointment_technician_update')
    ,('guard_customer_self_update')
    ,('guard_notification_recipient_update')
    ,('guard_profile_privileged_columns')
    ,('guard_profile_staff_role_key')
    ,('guard_technician_tier_change')
    ,('set_updated_at')
    ,('stamp_technician_tier_changed_at')
), f as (
  select p.oid, p.oid::regprocedure::text as sig, p.proname as name, p.prosecdef as definer,
         pg_get_function_result(p.oid) as ret, p.proacl,
         (p.prorettype = 'trigger'::regtype) as is_trigger,
         (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')) as has_public,
         exists (select 1 from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE'
                  and a.grantee = (select oid from pg_roles where rolname = 'anon')) as has_anon,
         exists (select 1 from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE'
                  and a.grantee = (select oid from pg_roles where rolname = 'authenticated')) as has_auth
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.proowner = 'postgres'::regrole and p.prokind in ('f', 'p')
)
select f.sig,
       case when f.is_trigger or tg.name is not null then 'trigger group' else 'callable' end as grp,
       f.definer, f.has_public, f.has_anon, f.has_auth,
       case when f.is_trigger or tg.name is not null then 'REVOKE authenticated'
            when f.has_public or f.has_auth then 'GRANT authenticated (explicit)'
            else 'no authenticated' end as authenticated_action,
       case when f.name = any (array['_attendance_compute_status', '_auto_draft_purchase_order', '_detect_ticket_type', '_gift_create_inventory_row', '_gift_log_decrement_stock', '_milestone_invoice_notify', '_milestone_ticket_notify', '_milestone_visit_notify', '_notify_customer_ticket_milestone', '_notify_customer_visit_started', '_notify_task_assigned', '_notify_technician_low_stock', '_on_attendance_present_assign_backlog', '_po_task_completed_marks_paid', '_service_tickets_derive_skill_and_duration', '_technicians_deactivate_clears_duty', '_wa_numbers_valid', 'admin_override_visit_completion', 'admin_sign_spare_handover', 'approve_purchase_order', 'assign_ticket_technician', 'audit_master_change', 'audit_profile_changes', 'auto_assign_ticket', 'award_referral_points', 'book_service_ticket', 'cancel_service_ticket', 'complete_appointment', 'compute_incentives', 'compute_salary', 'confirm_spare_handover', 'create_bill_entry', 'create_complaint_ticket', 'create_purchase_order', 'create_quotation', 'create_rental', 'create_sale', 'create_service_invoice', 'create_spare_handover', 'create_spare_return', 'current_customer_id', 'current_org_id', 'current_role', 'current_technician_id', 'current_technician_is_active', 'customer_owns_appointment', 'customer_sees_technician', 'customer_sees_technician_profile', 'delete_my_address', 'delete_service_ticket', 'enforce_customer_members_limit', 'generate_visit_otp', 'get_technician_public_stats', 'get_visit_payment_state', 'guard_appointment_technician_update', 'guard_customer_self_update', 'guard_notification_recipient_update', 'guard_profile_privileged_columns', 'guard_profile_staff_role_key', 'guard_technician_tier_change', 'is_master', 'is_ops_staff', 'is_sales_staff', 'is_staff', 'is_technician_customer', 'list_my_tickets_filtered', 'log_confirmed_availability', 'log_purchase_quote_reply', 'log_technician_google_review', 'mark_po_paid', 'mark_quote_supplier_no_response', 'mark_rental_returned', 'record_additional_payment', 'record_payment_proof', 'record_technician_arrival_address', 'record_upi_payment', 'refresh_amc_statuses', 'refresh_operational_alerts', 'register_product_via_qr', 'renew_amc_plan', 'request_callback', 'resolve_purchase_quote_requests', 'resolve_stale_bookings', 'reward_candidates', 'sell_amc_plan_onsite', 'set_item_standard_time', 'set_primary_member', 'set_updated_at', 'stamp_technician_tier_changed_at', 'submit_customer_enquiry', 'submit_customer_rating', 'submit_rating', 'technician_kpi_summary', 'technician_respond_shift_end_prompt', 'update_po_items_and_approve', 'verify_visit_otp']) then 'audited' else 'UNLISTED' end as audit_status,
       f.proacl::text as current_acl
from f left join trigger_group tg on tg.name = f.name
where f.proacl is null or f.has_public or f.has_anon
order by 2, 1;
