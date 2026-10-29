-- Rollback for 20261116100000_close_outstanding_reminders_bulk.sql
drop function if exists public.close_outstanding_reminders_if_zero_bulk();
