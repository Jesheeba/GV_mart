-- GV Mart — extensions & enum types
-- Authority order: GVMart-Requirement-Confirmation v2.2.pdf > Design Deltas > Vite Implementation Plan
-- Data model source: GV_Mart_ClaudeCode_BuildSpec.md §5 (Vite plan §6: reuse the Supabase schema verbatim)

create extension if not exists pgcrypto;

create type user_role as enum ('master', 'operation_admin', 'sales_admin', 'technician', 'customer');
create type brand_category as enum ('ro', 'ac', 'inverter', 'battery');
create type item_type as enum ('product', 'spare');
create type location_type as enum ('warehouse', 'van');
create type address_type as enum ('residential', 'commercial');
create type ownership_type as enum ('own', 'rental');
create type po_status as enum ('draft', 'sent', 'received');
create type quotation_status as enum ('open', 'converted', 'lost');
create type invoice_type as enum ('product', 'spare', 'amc');
create type payment_method as enum ('cash', 'transfer');
create type payment_status as enum ('paid', 'partial', 'due');
create type ticket_type as enum ('paid', 'warranty', 'amc');
create type priority_level as enum ('very_urgent', 'urgent', 'normal');
create type ticket_status as enum ('open', 'assigned', 'in_progress', 'completed', 'cancelled');
create type ticket_channel as enum ('call', 'whatsapp', 'walk_in', 'customer_app', 'field');
create type appointment_mode as enum ('always', 'datetime');
create type appointment_status as enum ('scheduled', 'in_progress', 'completed', 'cancelled');
create type amc_status as enum ('active', 'due_soon', 'expired');
create type enquiry_type as enum ('online', 'price', 'quality', 'customization', 'water_premium', 'budget');
create type lead_status as enum ('new', 'contacted', 'quoted', 'won', 'lost');
create type lead_source as enum ('field', 'customer_app', 'whatsapp', 'walk_in', 'referral', 'other');
create type automation_action as enum ('send_video', 'quotation', 'link');
create type incentive_type as enum ('service_income', 'sales_income', 'review');
create type reward_category as enum ('attendance', 'highest_review', 'highest_revenue');
create type expense_category as enum ('marketing', 'stationery', 'salary', 'petrol', 'purchase', 'other');
create type approval_type as enum ('discount', 'po', 'price_override', 'leave');
create type approval_status as enum ('pending', 'approved', 'rejected');
create type task_status as enum ('open', 'done', 'rolled');
