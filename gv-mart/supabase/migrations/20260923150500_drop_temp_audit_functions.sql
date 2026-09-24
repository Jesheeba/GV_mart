-- Cleanup: drop the two temporary diagnostic functions used to verify
-- 20260923150000/150400 (they were only meant to inspect pg_proc.proacl
-- directly and were never intended to stay in production).
drop function if exists public._audit_check_execute_grants();
drop function if exists public._audit_check_execute_grants_v2();
