-- Rollback for 20261024100000_close_public_and_anon_function_execute.sql
-- Restores the EXACT prior ACLs recorded in the snapshot file next to this one
-- (20261024100000_close_public_and_anon_function_execute.acl_snapshot.json, taken 2026-10-14 before the migration), then the prior default privileges.
-- WARNING: this re-opens PUBLIC and anon EXECUTE on 97 functions and re-opens the PUBLIC default
-- for new functions. It is a restore-the-prior-state tool, not a routine undo.
-- Functions created after the snapshot (for example AMC helpers) are not in it and are left as the
-- migration set them.

do $rb$
declare
  v_sig text;
begin
  -- prior ACL grantees (besides postgres): anon,authenticated,public,service_role; 72 functions
  foreach v_sig in array array[
    '"current_role"()',
    '_attendance_compute_status()',
    '_auto_draft_purchase_order()',
    '_detect_ticket_type(uuid,uuid,uuid)',
    '_gift_create_inventory_row()',
    '_gift_log_decrement_stock()',
    '_milestone_invoice_notify()',
    '_milestone_ticket_notify()',
    '_milestone_visit_notify()',
    '_notify_customer_ticket_milestone()',
    '_notify_customer_visit_started()',
    '_on_attendance_present_assign_backlog()',
    '_service_tickets_derive_skill_and_duration()',
    '_technicians_deactivate_clears_duty()',
    'admin_override_visit_completion(uuid,uuid,text)',
    'admin_sign_spare_handover(uuid,text)',
    'approve_purchase_order(uuid)',
    'assign_ticket_technician(uuid,uuid,boolean)',
    'audit_master_change()',
    'auto_assign_ticket(uuid)',
    'award_referral_points(uuid,uuid,integer,text,uuid)',
    'book_service_ticket(uuid,uuid,uuid,uuid,uuid,text,text,priority_level,date,jsonb,uuid)',
    'cancel_service_ticket(uuid,text)',
    'complete_appointment(uuid)',
    'compute_incentives(uuid,date)',
    'confirm_spare_handover(uuid,text,text)',
    'create_bill_entry(uuid,uuid,uuid,jsonb,numeric,date,text,expense_category)',
    'create_complaint_ticket(uuid,uuid,uuid,uuid,uuid,uuid,text,text,priority_level,ticket_channel,appointment_mode,boolean,date,uuid,uuid,text,uuid)',
    'create_purchase_order(uuid,uuid,jsonb)',
    'create_quotation(uuid,uuid,date,jsonb,uuid)',
    'create_sale(uuid,uuid,jsonb,uuid,integer,uuid,numeric)',
    'create_spare_handover(uuid,uuid,date,jsonb)',
    'current_customer_id()',
    'current_org_id()',
    'current_technician_id()',
    'current_technician_is_active()',
    'customer_owns_appointment(uuid)',
    'customer_sees_technician(uuid)',
    'customer_sees_technician_profile(uuid)',
    'delete_my_address(uuid)',
    'delete_service_ticket(uuid)',
    'enforce_customer_members_limit()',
    'generate_visit_otp(uuid,uuid,boolean)',
    'get_technician_public_stats(uuid)',
    'get_visit_payment_state(uuid,uuid)',
    'is_master()',
    'is_ops_staff()',
    'is_sales_staff()',
    'is_staff()',
    'is_technician_customer(uuid)',
    'list_my_tickets_filtered(date,date,text,ticket_status,amc_status,ticket_type,uuid,text,text,integer,integer)',
    'log_confirmed_availability(uuid,text,date,time without time zone,time without time zone,text)',
    'log_purchase_quote_reply(uuid,uuid,numeric,text)',
    'record_additional_payment(uuid,uuid,numeric,payment_method,text,text)',
    'record_payment_proof(uuid,uuid,text,text)',
    'record_upi_payment(uuid,uuid)',
    'refresh_amc_statuses(uuid)',
    'refresh_operational_alerts(uuid)',
    'register_product_via_qr(uuid,uuid,text,date)',
    'renew_amc_plan(uuid,uuid,uuid,text,integer,text,uuid)',
    'request_callback(uuid,date,uuid,uuid,text)',
    'resolve_purchase_quote_requests(uuid)',
    'resolve_stale_bookings(uuid)',
    'reward_candidates(uuid,date)',
    'sell_amc_plan_onsite(uuid,uuid,uuid,uuid,payment_method,text,text,numeric)',
    'set_item_standard_time(uuid,item_type,uuid,integer)',
    'set_primary_member(uuid,uuid)',
    'set_updated_at()',
    'submit_customer_enquiry(uuid,text,enquiry_type,text,text,uuid,jsonb)',
    'submit_customer_rating(uuid,uuid,numeric,text)',
    'submit_rating(uuid,uuid,numeric,text,text)',
    'verify_visit_otp(uuid,uuid,text,boolean,text)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated, service_role', v_sig);
    execute format('grant execute on function %s to anon, authenticated, public, service_role', v_sig);
  end loop;
  -- prior ACL grantees (besides postgres): public,service_role; 14 functions
  foreach v_sig in array array[
    '_notify_task_assigned()',
    '_notify_technician_low_stock()',
    '_po_task_completed_marks_paid()',
    '_wa_numbers_valid(text[])',
    'audit_profile_changes()',
    'create_spare_return(uuid,uuid,date,jsonb)',
    'guard_appointment_technician_update()',
    'guard_customer_self_update()',
    'guard_notification_recipient_update()',
    'guard_profile_privileged_columns()',
    'guard_profile_staff_role_key()',
    'guard_technician_tier_change()',
    'sell_amc_plan(uuid,uuid,uuid,uuid,date,integer,uuid)',
    'stamp_technician_tier_changed_at()'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated, service_role', v_sig);
    execute format('grant execute on function %s to public, service_role', v_sig);
  end loop;
  -- prior ACL grantees (besides postgres): authenticated,public,service_role; 11 functions
  foreach v_sig in array array[
    'compute_salary(uuid,uuid,date)',
    'create_rental(uuid,uuid,uuid,uuid,uuid,date,payment_method,text,text)',
    'create_service_invoice(uuid,uuid,numeric,numeric,jsonb,payment_method,text,text,boolean,numeric,jsonb)',
    'log_technician_google_review(uuid,uuid,uuid,smallint,text)',
    'mark_po_paid(uuid)',
    'mark_quote_supplier_no_response(uuid,uuid)',
    'mark_rental_returned(uuid,uuid)',
    'record_technician_arrival_address(uuid,uuid,numeric,numeric)',
    'technician_kpi_summary(uuid,uuid)',
    'technician_respond_shift_end_prompt(text)',
    'update_po_items_and_approve(uuid,jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated, service_role', v_sig);
    execute format('grant execute on function %s to authenticated, public, service_role', v_sig);
  end loop;
end
$rb$;

-- Prior default privileges: no global row existed for postgres; granting PUBLIC returns the built-in default
-- (the row is removed when it equals the built-in default).
alter default privileges for role postgres grant execute on functions to public;
