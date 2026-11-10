-- Rollback for 20261204140000_customer_needs_review_notify.sql.
-- Everything this migration added is brand new (the trigger and its function) -- nothing is
-- redefined, no column/type changes on any existing table. Dropping the trigger, then the
-- function, then removing the schema_migrations row is the complete undo. Any task/notification
-- rows the trigger already created before rollback are left alone (real data, not this
-- migration's own objects) -- same "undo the migration, not the data it produced" convention as
-- every other rollback in this project.
drop trigger if exists customers_needs_review_notify on public.customers;
drop function if exists public._notify_customer_needs_review();
delete from supabase_migrations.schema_migrations where version = '20261204140000';
