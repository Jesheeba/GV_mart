-- Video language (2026-10-14), part of the Automations enquiry-video design (docs/automations-flows-design.md, section 9).
--
-- WRITTEN, NOT APPLIED. Nothing here is live until it is applied by name.
--
-- 1. product_videos.language and video_library.language: nullable, 'en' | 'ta'. NULL means "any language", so every existing
--    row keeps working exactly as it does today (the customer app lists all active videos regardless of language).
-- 2. spare_videos: new table mirroring product_videos (a spare had no video storage), with the same nullable language.
--
-- Not in this migration (engine side, owned by the automation work): the resolver that picks a video by language, the item
-- key, the cooldown, the hand-off. Nothing reads language yet except the admin forms.
--
-- Deleting a spare removes its videos (ON DELETE CASCADE). Unlike products, spare_videos is NOT added to
-- spare_has_references: videos are configuration, not history, and that function is also redefined on other branches.

alter table public.product_videos
  add column if not exists language text check (language is null or language in ('en', 'ta'));

alter table public.video_library
  add column if not exists language text check (language is null or language in ('en', 'ta'));

create table public.spare_videos (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  spare_id uuid not null references public.spares (id) on delete cascade,
  url text not null,
  title text,
  language text check (language is null or language in ('en', 'ta')),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index spare_videos_org_id_idx on public.spare_videos (org_id);
create index spare_videos_spare_id_idx on public.spare_videos (spare_id);

alter table public.spare_videos enable row level security;
create policy spare_videos_select_org on public.spare_videos for select using (org_id = public.current_org_id());
create policy spare_videos_write_master on public.spare_videos for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());

create trigger audit_spare_videos after insert or update or delete on public.spare_videos
  for each row execute function public.audit_master_change();
create trigger set_updated_at before update on public.spare_videos
  for each row execute function public.set_updated_at();

-- Same privilege posture as product_videos after 20261016500000 (anon has no table privileges).
revoke all on public.spare_videos from anon;
