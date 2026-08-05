-- Seed sensible product<->spare mappings by category (2026-08-05).
--
-- product_spares (20260730170000_product_spare_mapping_and_active_flags.sql)
-- was built for admins to curate per-product (Masters > Products > Spares
-- panel), but was never actually populated beyond one stray test row — so
-- CustomerSpareEnquiryPage's "Select spare part" list was empty for
-- virtually every product. spares has no category column (a deliberate
-- earlier call, see that migration's comment), but every seeded spare name
-- is unambiguously RO/AC/Inverter/Battery-specific and these parts are
-- generic across models within a category (a "RO Membrane" fits any RO
-- unit), so a one-time category-based bulk link is a reasonable real
-- default — admins can still add/remove individual mappings afterward via
-- the existing panel.

insert into public.product_spares (org_id, product_id, spare_id)
select p.org_id, p.id, s.id
from public.products p
join public.spares s on s.org_id = p.org_id
join (
  values
    ('Pre-Carbon Filter (RO)', 'ro'),
    ('Post-Carbon Filter (RO)', 'ro'),
    ('Sediment Filter (RO)', 'ro'),
    ('RO Membrane 75 GPD', 'ro'),
    ('UV Lamp', 'ro'),
    ('UF Membrane', 'ro'),
    ('Solenoid Valve', 'ro'),
    ('Booster Pump', 'ro'),
    ('SMPS Adapter 24V', 'ro'),
    ('TDS Controller', 'ro'),
    ('Float Valve', 'ro'),
    ('Storage Tank 8L', 'ro'),
    ('Non-Return Valve (NRV)', 'ro'),
    ('AC Cooling Coil', 'ac'),
    ('AC PCB Board', 'ac'),
    ('AC Remote Control', 'ac'),
    ('Gas Refill Can R32 (1kg)', 'ac'),
    ('AC Compressor Capacitor', 'ac'),
    ('Battery Terminal Connector', 'battery'),
    ('Inverter Fuse', 'inverter')
) as cat(spare_name, category) on cat.spare_name = s.name
where p.category = cat.category::public.brand_category
  and p.is_active
  and s.is_active
on conflict (product_id, spare_id) do nothing;
