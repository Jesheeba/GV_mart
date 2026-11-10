-- P1b (security audit): a deactivated technician is not a technician for RLS.
-- Design: gv-mart/docs/design-p1-task-security.md
--
-- current_technician_id() now also requires technicians.is_active. Every policy and function that keys on it (tasks, jobs, customer
-- history, ...) stops matching a deactivated technician immediately. create or replace keeps the existing ACL (one of the helper
-- functions that must stay executable by the roles RLS runs as).
--
-- Rollback: supabase/rollbacks/20261101110000_current_technician_id_active.rollback.sql

create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select t.id from public.technicians t where t.profile_id = auth.uid() and t.is_active $$;
