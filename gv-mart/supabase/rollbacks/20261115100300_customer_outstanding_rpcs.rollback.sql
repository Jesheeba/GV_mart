drop function if exists public.create_customer_outstanding_reminder(uuid, timestamptz, text, uuid, numeric);
drop function if exists public.reschedule_customer_outstanding_reminder(uuid, timestamptz, text);
drop function if exists public.close_customer_outstanding_reminder(uuid);
drop function if exists public.cancel_customer_outstanding_reminder(uuid, text);
drop function if exists public.create_customer_outstanding_task(uuid, uuid, text, date, uuid, numeric);
drop function if exists public.close_outstanding_reminders_if_zero(uuid);
