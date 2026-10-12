-- Automation Phase 3 / Stage A, part 2 (S2): customers.preferred_language.
--
-- 'en' | 'ta', nullable; empty means English (the engine's order is: preferred_language, the login's profiles.language,
-- the rule's language, 'en'). Backfilled once from the login language where a login exists. The backfill runs with
-- triggers off for that single statement (session_replication_role = replica, transaction-local) so it does not bump
-- customers.updated_at or write an audit row for every customer: it is a mechanical default, not a user edit.

alter table public.customers
  add column preferred_language text check (preferred_language in ('en', 'ta'));

set local session_replication_role = replica;
update public.customers c
   set preferred_language = p.language
  from public.profiles p
 where p.id = c.primary_profile_id
   and p.language in ('en', 'ta')
   and c.preferred_language is null;
set local session_replication_role = origin;
