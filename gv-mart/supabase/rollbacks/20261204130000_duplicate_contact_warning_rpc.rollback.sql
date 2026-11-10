-- Rollback for 20261204130000_duplicate_contact_warning_rpc.sql.
-- Everything this migration added is brand new (find_duplicate_contacts) or a pure grant
-- widening on an existing, otherwise-untouched function (_mobile_key -> authenticated) --
-- nothing is redefined, no column/type changes on any existing table. Dropping the new
-- function, revoking the grant, and removing the schema_migrations row is the complete undo.
-- Safe to run at any time: find_duplicate_contacts is STABLE/read-only and holds no state of
-- its own.
drop function if exists public.find_duplicate_contacts(text, text);
revoke execute on function public._mobile_key(text) from authenticated;
delete from supabase_migrations.schema_migrations where version = '20261204130000';
