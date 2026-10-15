-- Rollback for 20261028100000_enquiry_video_resolver.sql. The migration adds two read-only functions and nothing else (no table,
-- column, trigger or data), so this removes exactly those two. Nothing may be calling them yet; if the hand-off (item 3 part 2)
-- has been applied, roll that back first.
begin;
drop function if exists public._automation_lead_enquiry_video(uuid, uuid, text, text, integer);
drop function if exists public._automation_enquiry_video(uuid, uuid, uuid, text, integer);
commit;
