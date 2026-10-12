-- Rollback for 20261018110000_customer_preferred_language.sql. The column holds only a mechanical backfill and user choices;
-- dropping it loses the choices. Run AFTER the rollback of 20261018120000 (the engine reads it).
begin;
alter table public.customers drop column if exists preferred_language;
commit;
