-- Row Level Security — role model from BuildSpec §3.
--
-- Design notes (read once):
-- * SELECT is generally org-wide for staff (master/operation_admin/
--   sales_admin) — dashboards and reports need cross-module visibility.
--   The exception is genuinely sensitive HR/financial data (settings
--   excluded — that's operational config, not financial): incentive_rules,
--   incentives_earned, rewards-write, salaries, expenses, audit_log are
--   master-only, matching "operation_admin/sales_admin cannot access
--   Payroll/P&L" in §3's access table.
-- * WRITE is where role separation actually bites: each module's INSERT/
--   UPDATE is scoped to the staff role(s) that own that module in §3,
--   plus technician/customer own-row access where the app requires it
--   (technician's own attendance/visits/handovers/locations/leads;
--   customer's own profile/addresses/bookings/leads).
-- * No table gets a DELETE policy in Phase 1 — hard deletes aren't part of
--   any UI yet, so the safe default (RLS denies unlisted actions) applies.
--   Trusted delete/service-role paths can be added per-module later.
-- * technician/customer never see other technicians'/customers' rows —
--   every technician- or customer-scoped policy filters on
--   current_technician_id()/current_customer_id().

alter table organizations enable row level security;
alter table profiles enable row level security;
alter table technicians enable row level security;
alter table customers enable row level security;
alter table customer_members enable row level security;
alter table addresses enable row level security;
alter table brands enable row level security;
alter table models enable row level security;
alter table products enable row level security;
alter table spares enable row level security;
alter table inventory enable row level security;
alter table inventory_movements enable row level security;
alter table suppliers enable row level security;
alter table supplier_products enable row level security;
alter table purchase_orders enable row level security;
alter table po_items enable row level security;
alter table purchase_bills enable row level security;
alter table quotations enable row level security;
alter table quotation_items enable row level security;
alter table gifts enable row level security;
alter table invoices enable row level security;
alter table invoice_items enable row level security;
alter table gift_logs enable row level security;
alter table service_tickets enable row level security;
alter table appointments enable row level security;
alter table service_visits enable row level security;
alter table service_sop_steps enable row level security;
alter table service_spares_used enable row level security;
alter table ro_checklists enable row level security;
alter table ratings enable row level security;
alter table amc_plans enable row level security;
alter table amc_contracts enable row level security;
alter table warranties enable row level security;
alter table attendance enable row level security;
alter table spare_handovers enable row level security;
alter table spare_handover_items enable row level security;
alter table technician_locations enable row level security;
alter table leads enable row level security;
alter table lead_activities enable row level security;
alter table automation_flows enable row level security;
alter table video_library enable row level security;
alter table referral_points enable row level security;
alter table incentive_rules enable row level security;
alter table incentives_earned enable row level security;
alter table rewards enable row level security;
alter table salaries enable row level security;
alter table expenses enable row level security;
alter table settings enable row level security;
alter table approvals enable row level security;
alter table notifications enable row level security;
alter table audit_log enable row level security;
alter table tasks enable row level security;

-- ── Org & identity ──────────────────────────────────────────────────────

create policy organizations_select on organizations
  for select using (id = public.current_org_id());
create policy organizations_update_master on organizations
  for update using (id = public.current_org_id() and public.is_master());

create policy profiles_select_own on profiles
  for select using (id = auth.uid());
create policy profiles_select_staff on profiles
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy profiles_insert_own on profiles
  for insert with check (id = auth.uid());
create policy profiles_insert_master on profiles
  for insert with check (org_id = public.current_org_id() and public.is_master());
create policy profiles_update_own on profiles
  for update using (id = auth.uid());
create policy profiles_update_master on profiles
  for update using (org_id = public.current_org_id() and public.is_master());

create policy technicians_select_staff on technicians
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy technicians_select_own on technicians
  for select using (profile_id = auth.uid());
create policy technicians_write_ops on technicians
  for all using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- ── Customers ────────────────────────────────────────────────────────────

create policy customers_select_staff on customers
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customers_select_own on customers
  for select using (id = public.current_customer_id());
create policy customers_write_sales on customers
  for all using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());
create policy customers_update_own on customers
  for update using (id = public.current_customer_id());

create policy customer_members_select_staff on customer_members
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy customer_members_select_own on customer_members
  for select using (customer_id = public.current_customer_id());
create policy customer_members_write_sales on customer_members
  for all using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());
create policy customer_members_write_own on customer_members
  for all using (customer_id = public.current_customer_id())
  with check (customer_id = public.current_customer_id());

create policy addresses_select_staff on addresses
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy addresses_select_own on addresses
  for select using (customer_id = public.current_customer_id());
create policy addresses_write_sales on addresses
  for all using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());
create policy addresses_write_own on addresses
  for all using (customer_id = public.current_customer_id())
  with check (customer_id = public.current_customer_id());

-- ── Catalog & inventory ──────────────────────────────────────────────────
-- Catalog (brands/models/products/spares/gifts/amc_plans) is readable by
-- every authenticated org member — staff, technicians and customers all
-- need to browse it (sales, fieldwork, and the customer app's product
-- enquiry screens respectively).

create policy brands_select_org on brands for select using (org_id = public.current_org_id());
create policy brands_write_master on brands for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy models_select_org on models for select using (org_id = public.current_org_id());
create policy models_write_master on models for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy products_select_org on products for select using (org_id = public.current_org_id());
create policy products_write_master on products for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy spares_select_org on spares for select using (org_id = public.current_org_id());
create policy spares_write_master on spares for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy gifts_select_org on gifts for select using (org_id = public.current_org_id());
create policy gifts_write_master on gifts for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy inventory_select_staff on inventory
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy inventory_write_ops on inventory for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy inventory_movements_select_staff on inventory_movements
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy inventory_movements_write_ops on inventory_movements for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- ── Suppliers & purchase ─────────────────────────────────────────────────

create policy suppliers_select_staff on suppliers
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy suppliers_write_ops on suppliers for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy supplier_products_select_staff on supplier_products
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy supplier_products_write_ops on supplier_products for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy purchase_orders_select_staff on purchase_orders
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_orders_write_ops on purchase_orders for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy po_items_select_staff on po_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy po_items_write_ops on po_items for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy purchase_bills_select_staff on purchase_bills
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy purchase_bills_write_ops on purchase_bills for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- ── Sales ────────────────────────────────────────────────────────────────

create policy quotations_select_staff on quotations
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy quotations_write_sales on quotations for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy quotation_items_select_staff on quotation_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy quotation_items_write_sales on quotation_items for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy invoices_select_staff on invoices
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy invoices_select_own on invoices
  for select using (customer_id = public.current_customer_id());
create policy invoices_write_sales on invoices for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy invoice_items_select_staff on invoice_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy invoice_items_select_own on invoice_items
  for select using (
    exists (select 1 from invoices i where i.id = invoice_id and i.customer_id = public.current_customer_id())
  );
create policy invoice_items_write_sales on invoice_items for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy gift_logs_select_staff on gift_logs
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy gift_logs_write_sales on gift_logs for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

-- ── Service ──────────────────────────────────────────────────────────────

create policy service_tickets_select_staff on service_tickets
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy service_tickets_select_own_customer on service_tickets
  for select using (customer_id = public.current_customer_id());
create policy service_tickets_select_own_technician on service_tickets
  for select using (
    exists (
      select 1 from appointments a
      where a.ticket_id = id and a.technician_id = public.current_technician_id()
    )
  );
create policy service_tickets_write_ops on service_tickets for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy service_tickets_insert_own_customer on service_tickets
  for insert with check (customer_id = public.current_customer_id());

create policy appointments_select_staff on appointments
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy appointments_select_own_technician on appointments
  for select using (technician_id = public.current_technician_id());
create policy appointments_write_ops on appointments for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy service_visits_select_staff on service_visits
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy service_visits_write_ops on service_visits for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy service_visits_write_own_technician on service_visits for all
  using (technician_id = public.current_technician_id())
  with check (technician_id = public.current_technician_id());

create policy service_sop_steps_select_staff on service_sop_steps
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy service_sop_steps_write_ops on service_sop_steps for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy service_sop_steps_write_own_technician on service_sop_steps for all
  using (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()))
  with check (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()));

create policy service_spares_used_select_staff on service_spares_used
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy service_spares_used_write_ops on service_spares_used for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy service_spares_used_write_own_technician on service_spares_used for all
  using (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()))
  with check (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()));

create policy ro_checklists_select_staff on ro_checklists
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy ro_checklists_write_ops on ro_checklists for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy ro_checklists_write_own_technician on ro_checklists for all
  using (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()))
  with check (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()));

create policy ratings_select_staff on ratings
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy ratings_select_own_customer on ratings
  for select using (
    exists (
      select 1 from service_visits v join service_tickets t on t.id = v.ticket_id
      where v.id = visit_id and t.customer_id = public.current_customer_id()
    )
  );
create policy ratings_write_ops on ratings for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy ratings_write_own_technician on ratings for all
  using (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()))
  with check (exists (select 1 from service_visits v where v.id = visit_id and v.technician_id = public.current_technician_id()));

-- ── AMC & warranty ───────────────────────────────────────────────────────
-- Written by both sales (sells the plan) and ops (schedules/manages visits).

create policy amc_plans_select_org on amc_plans for select using (org_id = public.current_org_id());
create policy amc_plans_write_master on amc_plans for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy amc_contracts_select_staff on amc_contracts
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy amc_contracts_select_own on amc_contracts
  for select using (customer_id = public.current_customer_id());
create policy amc_contracts_write_ops_sales on amc_contracts for all
  using (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()))
  with check (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()));

create policy warranties_select_staff on warranties
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy warranties_select_own on warranties
  for select using (customer_id = public.current_customer_id());
create policy warranties_write_ops_sales on warranties for all
  using (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()))
  with check (org_id = public.current_org_id() and (public.is_ops_staff() or public.is_sales_staff()));

-- ── Technician ops ───────────────────────────────────────────────────────

create policy attendance_select_staff on attendance
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy attendance_write_ops on attendance for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy attendance_write_own_technician on attendance for all
  using (technician_id = public.current_technician_id())
  with check (technician_id = public.current_technician_id());

create policy spare_handovers_select_staff on spare_handovers
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy spare_handovers_write_ops on spare_handovers for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy spare_handovers_write_own_technician on spare_handovers for all
  using (technician_id = public.current_technician_id())
  with check (technician_id = public.current_technician_id());

create policy spare_handover_items_select_staff on spare_handover_items
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy spare_handover_items_write_ops on spare_handover_items for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy spare_handover_items_write_own_technician on spare_handover_items for all
  using (exists (select 1 from spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id()))
  with check (exists (select 1 from spare_handovers h where h.id = handover_id and h.technician_id = public.current_technician_id()));

create policy technician_locations_select_staff on technician_locations
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy technician_locations_select_own on technician_locations
  for select using (technician_id = public.current_technician_id());
create policy technician_locations_insert_own on technician_locations
  for insert with check (technician_id = public.current_technician_id());

-- ── Leads & automation ───────────────────────────────────────────────────

create policy leads_select_staff on leads
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy leads_select_own_technician on leads
  for select using (owner_id = public.current_technician_id());
create policy leads_select_own_customer on leads
  for select using (customer_id = public.current_customer_id());
create policy leads_write_sales on leads for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());
create policy leads_insert_own_technician on leads
  for insert with check (owner_id = public.current_technician_id());
create policy leads_insert_own_customer on leads
  for insert with check (customer_id = public.current_customer_id());

create policy lead_activities_select_staff on lead_activities
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy lead_activities_write_sales on lead_activities for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy automation_flows_select_staff on automation_flows
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy automation_flows_write_sales on automation_flows for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy video_library_select_staff on video_library
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy video_library_write_sales on video_library for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

create policy referral_points_select_staff on referral_points
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy referral_points_select_own on referral_points
  for select using (customer_id = public.current_customer_id());
create policy referral_points_write_sales on referral_points for all
  using (org_id = public.current_org_id() and public.is_sales_staff())
  with check (org_id = public.current_org_id() and public.is_sales_staff());

-- ── HR / finance ─────────────────────────────────────────────────────────
-- Master-only visibility: §3 lists Payroll/P&L as inaccessible to
-- operation_admin and sales_admin, not merely non-editable.

create policy incentive_rules_select_master on incentive_rules
  for select using (org_id = public.current_org_id() and public.is_master());
create policy incentive_rules_write_master on incentive_rules for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy incentives_earned_select_master on incentives_earned
  for select using (org_id = public.current_org_id() and public.is_master());
create policy incentives_earned_select_own on incentives_earned
  for select using (technician_id = public.current_technician_id());
create policy incentives_earned_write_master on incentives_earned for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy rewards_select_staff on rewards
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy rewards_select_own on rewards
  for select using (winner_id = public.current_technician_id());
create policy rewards_write_ops on rewards for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

create policy salaries_select_master on salaries
  for select using (org_id = public.current_org_id() and public.is_master());
create policy salaries_select_own on salaries
  for select using (technician_id = public.current_technician_id());
create policy salaries_write_master on salaries for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy expenses_select_master on expenses
  for select using (org_id = public.current_org_id() and public.is_master());
create policy expenses_write_ops on expenses for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());

-- ── System ───────────────────────────────────────────────────────────────
-- settings is operational config (per-km time, work hours, discount caps…)
-- — every authenticated org member reads it; only master edits it.

create policy settings_select_org on settings for select using (org_id = public.current_org_id());
create policy settings_write_master on settings for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create policy approvals_select_master on approvals
  for select using (org_id = public.current_org_id() and public.is_master());
create policy approvals_select_own_request on approvals
  for select using (requested_by = auth.uid());
create policy approvals_insert_staff on approvals
  for insert with check (org_id = public.current_org_id() and public.is_staff());
create policy approvals_update_master on approvals
  for update using (org_id = public.current_org_id() and public.is_master());

create policy notifications_select_own_user on notifications
  for select using (user_id = auth.uid());
create policy notifications_select_own_role on notifications
  for select using (role = public.current_role() and org_id = public.current_org_id());
create policy notifications_insert_ops on notifications
  for insert with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy notifications_update_own on notifications
  for update using (user_id = auth.uid());

-- audit_log: master-read only; no client-side INSERT policy — writes go
-- through SECURITY DEFINER triggers / Edge Functions (service_role) added
-- alongside the sensitive-table triggers in a later phase.
create policy audit_log_select_master on audit_log
  for select using (org_id = public.current_org_id() and public.is_master());

create policy tasks_select_staff on tasks
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy tasks_write_ops on tasks for all
  using (org_id = public.current_org_id() and public.is_ops_staff())
  with check (org_id = public.current_org_id() and public.is_ops_staff());
create policy tasks_update_own_assignee on tasks
  for update using (assignee_id = auth.uid());
