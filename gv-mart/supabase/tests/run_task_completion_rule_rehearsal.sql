-- Wrapper: rehearsal of 20261025100000_task_completion_rule.sql. NOT run by the build.
-- psql -f this-file, from gv-mart/supabase/tests. The migration and the test are two separate
-- statements inside one transaction that is always rolled back; the test block also ends in
-- RAISE 'RESULTS', so a commit is impossible even if the final ROLLBACK were removed.
begin;
\ir ../migrations/20261025100000_task_completion_rule.sql
\ir task_completion_rule.test.sql
rollback;
