-- Rollback for 20261101110000_current_technician_id_active.sql: restores the function without the is_active test
-- (a deactivated technician matches RLS again). Run only on purpose.
begin;
create or replace function public.current_technician_id()
returns uuid
language sql stable security definer set search_path = public
as $$ select id from public.technicians where profile_id = auth.uid() $$;
commit;
