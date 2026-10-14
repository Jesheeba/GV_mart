-- Rollback for 20261023100000_video_language.sql. Drops the language column from the two existing tables and the new
-- spare_videos table (and any videos stored in it). Existing video rows keep their url, title and order.

drop table if exists public.spare_videos;
alter table public.product_videos drop column if exists language;
alter table public.video_library drop column if exists language;
