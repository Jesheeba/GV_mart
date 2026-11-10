drop trigger if exists audit_customer_outstanding_reminders on public.customer_outstanding_reminders;
drop trigger if exists set_updated_at on public.customer_outstanding_reminders;
drop table if exists public.customer_outstanding_reminders;
drop type if exists public.customer_outstanding_reminder_status;
