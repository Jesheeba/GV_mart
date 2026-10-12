-- Rollback for 20261018100000_customer_comm_prefs.sql. Run AFTER the rollback of 20261018120000 (the engine calls
-- _automation_is_opted_out). Dropping the tables loses every STOP / STOP ALL record: customers who opted out would be
-- messageable again, so only roll back before the webhook change is deployed.
begin;
drop function if exists public._automation_is_opted_out(uuid, text, text);
drop function if exists public.set_customer_comm_pref(uuid, boolean, boolean);
drop function if exists public.wa_record_opt_out(uuid, text, text, text);
drop table if exists public.customer_comm_pref_events;
drop table if exists public.customer_comm_prefs;
commit;
