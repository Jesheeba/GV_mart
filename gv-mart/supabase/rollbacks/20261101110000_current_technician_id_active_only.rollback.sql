-- Rollback for 20261101110000_current_technician_id_active_only.sql
-- original definition (20260701091200_functions_triggers.sql): no is_active test
create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;
