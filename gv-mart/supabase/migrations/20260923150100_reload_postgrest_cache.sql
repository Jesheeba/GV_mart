-- Force PostgREST to reload its schema/privilege cache after the REVOKEs in
-- 20260923150000, in case the automatic ddl_command_end reload didn't cover
-- these statements.
notify pgrst, 'reload schema';
