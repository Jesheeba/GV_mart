-- Close the anon role's table access, and stop new objects inheriting it. NOT applied until the owner approves.
--
-- Finding (2026-10-12 audit, docs/review-brief-independent.md, new scope item): this project's default privileges
-- grant the anon role every table privilege (SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN)
-- on every table the migrations create. 117 of 126 public relations carry them. Nothing is exposed today because
-- row-level security is on for every table and every policy reachable by anon needs an identity (verified by reading
-- the rows as anon, and by reading the policies), but that means one forgotten ENABLE ROW LEVEL SECURITY or one
-- permissive policy on a future table exposes it to anyone holding the public anon key. This removes the first layer
-- (the privilege itself) so RLS is no longer the only gate.
--
-- What this does NOT touch (by design):
--   * USAGE on schema public for anon (PostgREST needs it) and EXECUTE on any function. The 13 functions that must stay
--     anon-callable (current_role, current_org_id, current_customer_id, current_technician_id,
--     current_technician_is_active, is_master, is_ops_staff, is_staff, is_sales_staff, customer_owns_appointment,
--     customer_sees_technician, customer_sees_technician_profile, is_technician_customer) are called from RLS policies
--     as the invoking role. Function ACLs are not changed here.
--   * authenticated's SELECT / INSERT / UPDATE / DELETE (RLS keeps governing those), and sequences for authenticated.
--   * service_role and postgres.
--
-- Effect for a client holding only the anon key: a request to /rest/v1/<table> now fails with 42501 (permission
-- denied) instead of returning [] / a policy refusal. The app makes no anon table reads (login uses auth endpoints;
-- profile reads need a session), which the persona test confirms.

-- 1. existing objects: tables, partitioned tables, views, materialised views, foreign tables (ALL TABLES covers them)
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from public;
revoke all on all sequences in schema public from anon;
revoke all on all sequences in schema public from public;

-- 2. authenticated never needs these four: not reachable through the REST API, and TRUNCATE ignores RLS
revoke truncate, references, trigger, maintain on all tables in schema public from authenticated;

-- 3. default privileges for objects created later by the role that runs migrations here (postgres)
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;
alter default privileges for role postgres in schema public revoke truncate, references, trigger, maintain on tables from authenticated;

-- 4. the same for objects created by supabase_admin in this schema (Studio / extensions). Only possible when this
--    session may act for that role; if it cannot, say so loudly instead of failing the whole migration.
do $$
begin
  begin
    execute 'alter default privileges for role supabase_admin in schema public revoke all on tables from anon';
    execute 'alter default privileges for role supabase_admin in schema public revoke all on sequences from anon';
    execute 'alter default privileges for role supabase_admin in schema public revoke truncate, references, trigger, maintain on tables from authenticated';
  exception when insufficient_privilege then
    raise warning 'could not alter default privileges for role supabase_admin: run them as supabase_admin (objects created by that role in public still inherit anon privileges until then)';
  end;
end
$$;
