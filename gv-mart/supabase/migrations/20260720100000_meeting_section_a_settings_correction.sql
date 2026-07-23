-- Section A of GV_Mart_Meeting_Changes_2026-07-20.md — settings-wiring
-- corrections from the 20 Jul owner meeting.
--
-- A1/A3 were both already fully settings-driven (discount_tech_max/
-- discount_admin_max enforced as a hard block in create_sale/
-- create_service_invoice; per_km_minutes read live in the technician map's
-- ETA calc) — confirmed by reading every call site, no code change needed.
-- The only real gap: the STORED values are still the old v2.2 numbers
-- (5%/10% discount, 5 min/km), and a column DEFAULT only applies to a
-- brand-new row — it never retroactively changes the org's existing
-- `settings` row. So this migration does two things per corrected value:
-- (1) update the column DEFAULT, so any newly-onboarded org gets the
-- meeting's numbers from day one, and (2) UPDATE the existing row(s) so
-- this org's live behavior actually changes today.
--
-- A2 (working hours) is NOT touched here — it's already a single
-- settings-driven source (work_start/work_end) used consistently in
-- booking validation, exactly as asked. The exact end-time VALUE (7:00 vs
-- 7:30 vs 6:30) is explicitly still open pending the owner per the meeting
-- doc ("Until confirmed, keep it a single settings value used everywhere")
-- — left as-is (19:30) rather than guessed at.
--
-- A4 (AMC tiers) needed no migration at all — amc_plans.name is already a
-- free-text column, not a fixed enum; the master already supports adding
-- "Platinum Plus" or any other tier name with zero code change.

alter table public.settings
  alter column discount_tech_max set default 2,
  alter column discount_admin_max set default 5,
  alter column per_km_minutes set default 2;

update public.settings
set discount_tech_max = 2,
    discount_admin_max = 5,
    per_km_minutes = 2
where discount_tech_max = 5 and discount_admin_max = 10 and per_km_minutes = 5;
