-- NOT a migration. Report/plan artifact for the nightly-backup proposal —
-- run manually against production only after explicit confirmation, never
-- through the migration pipeline (this role and its grants are
-- infrastructure, not schema).
--
-- Verified against a from-scratch replay of the full migration history on
-- a disposable Postgres 17 container (public.ecr.aws/supabase/postgres:
-- 17.6.1.127), not against production:
--   - SELECT + schema USAGE alone is NOT enough: this app's RLS is
--     pervasive, and pg_dump as a plain SELECT-granted role fails with
--     "query would be affected by row-level security policy" on the first
--     RLS-enabled table it hits (addresses, in testing).
--   - The role also needs BYPASSRLS. Once granted, pg_dump succeeds.
--   - BYPASSRLS can be granted by the `postgres` role itself without full
--     superuser — Supabase's `postgres` role carries rolbypassrls=true and
--     rolcreaterole=true by design (confirmed on the test image, which
--     mirrors live Supabase project role setup), so this does not require
--     escalating beyond what the project's admin connection already has.
--   - Default privileges are included so a future migration's new table
--     doesn't silently fall outside the dump's coverage.

create role backup_reader with login password '<set a real password, do not commit it>';

grant usage on schema public to backup_reader;
grant select on all tables in schema public to backup_reader;
grant select on all sequences in schema public to backup_reader;
alter default privileges for role postgres in schema public grant select on tables to backup_reader;
alter default privileges for role postgres in schema public grant select on sequences to backup_reader;

alter role backup_reader bypassrls;

-- Scope is deliberately public-schema-only. auth.*/storage.* tables are
-- owned by supabase_auth_admin/supabase_admin respectively, not postgres,
-- so granting on them needs those roles specifically — out of scope here
-- since GV Mart's own data (everything this reconciliation/backup project
-- cares about) lives entirely in public. Revisit only if a restore ever
-- needs to recreate real auth.users identities rather than just app data.
