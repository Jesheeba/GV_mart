-- TDS-based RO recommendation on the customer profile (standalone feature,
-- unrelated to the WhatsApp bot or the Supplier RFQ pipeline). Client's
-- actual requirement: when staff open an existing customer's profile in the
-- CRM, the system should automatically suggest an RO product based on the
-- typical groundwater TDS for that customer's district — a regional
-- estimate, never a claim about that customer's own water.
--
-- Source data: Central Ground Water Board "Ground Water Quality Manual
-- Chemical Parameters" dataset, National Water Data Portal
-- (nwdp.nwic.gov.in), Tamil Nadu file, downloaded and verified directly
-- (8,419 station-records, TDS column present). District-level median/
-- min/max computed from all non-blank TDS readings per district; data_year
-- is the most recent year contributing a reading for that district. This
-- is a one-time import (see scripts/import-water-quality.mjs) — the bot's
-- zero-AI rule doesn't apply here, but the "no live scraping on every
-- request" principle does: this table is a static lookup, refreshed
-- manually (annually, matching CGWB's own update cadence), never queried
-- live from the government site.

create table public.water_quality_reference (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  district text not null,
  typical_tds_ppm numeric not null,
  tds_range_low numeric not null,
  tds_range_high numeric not null,
  sample_count integer not null default 0,
  data_source text not null default 'CGWB — National Water Data Portal (nwdp.nwic.gov.in)',
  data_year integer not null,
  updated_at timestamptz not null default now(),
  unique (org_id, district)
);

create index water_quality_reference_org_idx on public.water_quality_reference (org_id);

alter table public.water_quality_reference enable row level security;
create policy water_quality_reference_select_staff on public.water_quality_reference
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy water_quality_reference_write_master on public.water_quality_reference for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_water_quality_reference after insert or update or delete on public.water_quality_reference for each row execute function public.audit_master_change();

-- District-name resolution: a customer's address.district is free text
-- (pincode-lookup-filled, but staff can still type/paste variants — real
-- data already has "Trichy" and lowercase "pudukkottai"). Case-insensitive
-- match against water_quality_reference.district handles casing; this
-- table only carries genuinely different names, plus the one confirmed
-- proxy case: Chengalpattu was carved out of Kancheepuram in 2019 and CGWB
-- hasn't re-cut its historical data to the new boundary, so there is no
-- direct reading for it. is_proxy marks that so the UI can say "based on
-- nearby Kancheepuram-area data" instead of presenting it as a direct
-- Chengalpattu reading.
create table public.water_quality_district_aliases (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  alias text not null,
  canonical_district text not null,
  is_proxy boolean not null default false,
  proxy_note text,
  created_at timestamptz not null default now(),
  unique (org_id, alias)
);

create index water_quality_district_aliases_org_idx on public.water_quality_district_aliases (org_id);

alter table public.water_quality_district_aliases enable row level security;
create policy water_quality_district_aliases_select_staff on public.water_quality_district_aliases
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy water_quality_district_aliases_write_master on public.water_quality_district_aliases for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_water_quality_district_aliases after insert or update or delete on public.water_quality_district_aliases for each row execute function public.audit_master_change();

-- Band → product mapping. No structured capacity/stage/TDS-controller data
-- exists on products.custom_attributes for any live RO product, so this
-- can't be derived automatically — it's a manual admin pick (multiple
-- products per band allowed, sort_order controls which shows first).
create table public.product_tds_recommendations (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations (id) on delete cascade,
  band text not null check (band in ('low', 'medium', 'high')),
  product_id uuid not null references public.products (id) on delete cascade,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (org_id, band, product_id)
);

create index product_tds_recommendations_org_band_idx on public.product_tds_recommendations (org_id, band);

alter table public.product_tds_recommendations enable row level security;
create policy product_tds_recommendations_select_staff on public.product_tds_recommendations
  for select using (org_id = public.current_org_id() and public.is_staff());
create policy product_tds_recommendations_write_master on public.product_tds_recommendations for all
  using (org_id = public.current_org_id() and public.is_master())
  with check (org_id = public.current_org_id() and public.is_master());
create trigger audit_product_tds_recommendations after insert or update or delete on public.product_tds_recommendations for each row execute function public.audit_master_change();

-- ── Seed: real CGWB Tamil Nadu district data (imported 2026-09-02) ────────
insert into public.water_quality_reference
  (org_id, district, typical_tds_ppm, tds_range_low, tds_range_high, sample_count, data_year)
values
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Ariyalur', 387, 136, 2986.2, 12, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Chennai', 992.3, 705.6, 5657.4, 11, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Coimbatore', 1046, 173, 2167.2, 49, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Cuddalore', 548.1, 62, 5613.3, 29, 2023),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Dharmapuri', 980.2, 282.1, 2929.5, 46, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Dindigul', 186, 38.2, 2482.2, 40, 2021),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Erode', 858.5, 52.9, 5393, 82, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Kancheepuram', 811.1, 321.3, 3282.3, 38, 2021),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Kanyakumari', 368.5, 80.6, 1424.2, 40, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Karur', 1341.9, 466, 2570, 17, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Krishnagiri', 852.8, 181.4, 2432, 47, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Madurai', 166.8, 37.2, 2721.6, 24, 2021),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Nagapattinam', 863.1, 223, 1612.8, 15, 2023),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Namakkal', 1108, 191.8, 2388, 38, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Nilgiris', 244, 78.8, 2356.2, 13, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Perambalur', 1111.9, 264.6, 4303, 16, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Pudukkottai', 924.8, 157.5, 2702.7, 23, 2018),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Ramanathapuram', 1751.4, 261.5, 7100.1, 21, 2018),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Salem', 1110, 218, 7352.1, 65, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Sivaganga', 692.1, 190.9, 1814.4, 14, 2018),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Thanjavur', 786, 98.9, 4964.4, 23, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Theni', 163.6, 51.6, 2091.6, 22, 2021),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tiruchirappalli', 1167, 243.8, 3553.2, 36, 2023),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tirunelveli', 551, 59.9, 6552, 101, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tiruppur', 931.5, 174.5, 1814, 22, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tiruvallur', 1122.7, 680.4, 2419.2, 7, 2018),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tiruvannamalai', 773.5, 241.2, 1625.4, 25, 2021),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tiruvarur', 710.6, 197.2, 2431.8, 5, 2018),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Tuticorin', 712.5, 23.2, 7371, 62, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Vellore', 1017, 76.9, 4233.6, 37, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Viluppuram', 784, 119.7, 3178, 37, 2022),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'Virudhunagar', 1194, 64.2, 12506, 43, 2022);

insert into public.water_quality_district_aliases
  (org_id, alias, canonical_district, is_proxy, proxy_note)
values
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'trichy', 'Tiruchirappalli', false, null),
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'chengalpattu', 'Kancheepuram', true,
   'Chengalpattu was carved out of Kancheepuram district in 2019; CGWB''s published data still uses the pre-2019 boundary, so no direct reading exists for Chengalpattu — showing nearby Kancheepuram-area data instead.');

-- Default band → product picks (best-guess by price/model tier, since no
-- product carries structured capacity/TDS-controller data — staff should
-- review and adjust via Automation → TDS Recommendations).
insert into public.product_tds_recommendations (org_id, band, product_id, sort_order)
values
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'low', '9a93ac97-b9b2-4c6c-9468-e57493110dd0', 0), -- Livpure Glo Star RO+UV
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'medium', '3f7acc51-b9c2-40c5-a36f-19b5674fd059', 0), -- Kent Supreme RO
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'high', '111a6f30-fcaa-4cb2-a034-ea556f065f43', 0), -- Kent Grand Plus RO
  ('b6822905-5557-4e43-a606-f26ecfd5a541', 'high', '2d2f31b9-bebb-40bf-9031-aebb1b5ecfd1', 1); -- Aquaguard Enhance RO+UV+UF
