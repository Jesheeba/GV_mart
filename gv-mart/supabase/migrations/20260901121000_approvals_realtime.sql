-- PoApprovalPromptModal (Supplier Monthly RFQ pipeline, Phase 3) subscribes
-- to postgres_changes UPDATE on `approvals` so an operation_admin's
-- read-only copy of the popup closes itself the moment a master resolves
-- it elsewhere, without waiting on a poll. Same idempotent pattern as
-- 20260806110000_notifications_realtime.sql — a table only emits
-- postgres_changes once it's a member of the supabase_realtime publication,
-- and approvals was never added for any earlier feature.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'approvals'
  ) then
    alter publication supabase_realtime add table approvals;
  end if;
end $$;
