-- India Post reference directory (pincode -> district/state/taluk/office),
-- seeded for Tamil Nadu in the companion migration
-- 20261212110000_pincode_directory_seed_tamil_nadu.sql. Fixes: typing a
-- real, valid pincode that no customer had been saved with yet (e.g.
-- 622302) showed no District/State suggestion at all, because the Pincode
-- autocomplete and lookup only ever read the org's own `addresses` rows.
--
-- Global reference data, not org-scoped -- every org benefits from the same
-- postal directory, and it's non-sensitive public information. Read-only to
-- the app (seeded by migration only; no insert/update/delete policy, so
-- only migrations/service_role can write it).
create table public.pincode_directory (
  pincode text primary key,
  district text not null,
  state text not null,
  taluk text,
  office_name text,
  created_at timestamptz not null default now()
);

create index pincode_directory_district_idx on public.pincode_directory (district);

alter table public.pincode_directory enable row level security;

create policy pincode_directory_select_staff on public.pincode_directory for select using (public.is_staff());
